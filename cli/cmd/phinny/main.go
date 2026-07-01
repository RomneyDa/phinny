// Command phinny is Phinny's headless engine: a Go CLI that owns
// ~/.phinny/phinny.sqlite, syncs SimpleFIN, imports Apple Card statements,
// categorizes, detects transfers, and runs the mortgage math. The macOS app is
// a thin wrapper over `phinny serve --stdio`; any agent can drive the same
// surface via the one-shot subcommands or `phinny call <method>`.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/RomneyDa/phinny/cli/internal/rpc"
	"github.com/RomneyDa/phinny/cli/internal/service"
)

func main() {
	args := os.Args[1:]
	opts := service.Options{}
	var demoSource string

	// Global flags may appear before the command.
	var rest []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--db" && i+1 < len(args):
			opts.DBPath = args[i+1]
			i++
		case a == "--demo":
			opts.ForceDemo = true
		case a == "--demo-source" && i+1 < len(args):
			demoSource = args[i+1]
			i++
		case a == "-h" || a == "--help" || a == "help":
			usage()
			return
		default:
			rest = append(rest, args[i:]...)
			i = len(args)
		}
	}
	opts.DemoSource = demoSource

	if len(rest) == 0 {
		usage()
		return
	}
	cmd := rest[0]
	rest = rest[1:]

	if cmd == "methods" {
		for _, m := range rpc.Methods() {
			fmt.Println(m)
		}
		return
	}

	svc, err := service.Open(opts)
	if err != nil {
		fail("open", err.Error())
	}
	defer svc.Close()
	h := &rpc.Handler{Svc: svc}

	if cmd == "serve" {
		runServe(h, rest, demoSource)
		return
	}

	method, params, perr := mapCommand(cmd, rest)
	if perr != "" {
		fail("usage", perr)
	}
	raw, _ := json.Marshal(params)
	result, rpcErr := h.Handle(context.Background(), method, raw)
	if rpcErr != nil {
		failErr(rpcErr)
	}
	printJSON(result)
}

// mapCommand turns a friendly subcommand + args into a method name + params.
func mapCommand(cmd string, a []string) (string, map[string]any, string) {
	p := map[string]any{}
	switch cmd {
	case "status":
		return "status", p, ""
	case "dashboard":
		return "dashboard", p, ""
	case "sync":
		if has(a, "--force") {
			p["force"] = true
		}
		return "sync", p, ""
	case "connect":
		if len(a) < 1 {
			return "", nil, "connect <setup-token>"
		}
		p["token"] = a[0]
		return "connect", p, ""
	case "disconnect":
		return "disconnect", p, ""
	case "import":
		if len(a) < 1 {
			return "", nil, "import <file.csv|ofx|qfx|qbo>"
		}
		p["path"] = a[0]
		return "import", p, ""
	case "accounts":
		if len(a) >= 2 && (a[0] == "hide" || a[0] == "show") {
			p["id"] = a[1]
			p["hidden"] = a[0] == "hide"
			return "accounts.hide", p, ""
		}
		return "accounts.list", p, ""
	case "transactions", "txns":
		if v, ok := flagVal(a, "--limit"); ok {
			p["limit"], _ = strconv.Atoi(v)
		}
		if v, ok := flagVal(a, "--account"); ok {
			p["account"] = v
		}
		if v, ok := flagVal(a, "--since"); ok {
			n, _ := strconv.ParseInt(v, 10, 64)
			p["since"] = n
		}
		return "transactions.list", p, ""
	case "categories":
		if len(a) == 0 {
			return "categories.list", p, ""
		}
		switch a[0] {
		case "add":
			if len(a) < 2 {
				return "", nil, "categories add <name> [--color #HEX]"
			}
			p["name"] = a[1]
			if v, ok := flagVal(a, "--color"); ok {
				p["color"] = v
			}
			return "categories.add", p, ""
		case "rename":
			if len(a) < 3 {
				return "", nil, "categories rename <id> <name>"
			}
			p["id"] = a[1]
			p["name"] = a[2]
			return "categories.update", p, ""
		case "delete":
			if len(a) < 2 {
				return "", nil, "categories delete <id>"
			}
			p["id"] = a[1]
			return "categories.delete", p, ""
		}
		return "categories.list", p, ""
	case "categorize":
		if len(a) < 2 {
			return "", nil, "categorize <set|toggle|clear|manual|auto|remove> ..."
		}
		switch a[0] {
		case "set":
			p["transaction"] = a[1]
			if len(a) >= 3 {
				p["category"] = a[2]
			}
			return "categorize.set", p, ""
		case "toggle":
			if len(a) < 3 {
				return "", nil, "categorize toggle <txn> <category>"
			}
			p["transaction"] = a[1]
			p["category"] = a[2]
			return "categorize.toggle", p, ""
		case "clear":
			p["transaction"] = a[1]
			return "categorize.clear", p, ""
		case "manual", "auto":
			if len(a) < 3 {
				return "", nil, "categorize " + a[0] + " <txn> <category> [--start E] [--end E]"
			}
			p["transaction"] = a[1]
			p["category"] = a[2]
			if v, ok := flagVal(a, "--start"); ok {
				n, _ := strconv.ParseInt(v, 10, 64)
				p["start"] = n
			}
			if v, ok := flagVal(a, "--end"); ok {
				n, _ := strconv.ParseInt(v, 10, 64)
				p["end"] = n
			}
			return "categorize." + a[0], p, ""
		case "remove":
			p["id"] = a[1]
			return "categorize.removeLink", p, ""
		}
		return "", nil, "unknown categorize action: " + a[0]
	case "transfer":
		if len(a) < 1 {
			return "", nil, "transfer <mark|unmark|detect> [txn]"
		}
		switch a[0] {
		case "mark":
			p["transaction"] = a[1]
			return "transfers.mark", p, ""
		case "unmark":
			p["transaction"] = a[1]
			return "transfers.unmark", p, ""
		case "detect":
			return "transfers.detect", p, ""
		}
		return "", nil, "unknown transfer action: " + a[0]
	case "config":
		if len(a) >= 1 && a[0] == "set" {
			if v, ok := flagVal(a, "--min-interval-hours"); ok {
				n, _ := strconv.Atoi(v)
				p["min_interval_hours"] = n
			}
			if v, ok := flagVal(a, "--history-days"); ok {
				n, _ := strconv.Atoi(v)
				p["history_days"] = n
			}
			return "config.set", p, ""
		}
		return "config.get", p, ""
	case "mortgage", "mortgages":
		return mapMortgage(a)
	case "zillow":
		if len(a) >= 1 && a[0] == "fetch" {
			if len(a) < 2 {
				return "", nil, "zillow fetch <mortgage-id>"
			}
			p["mortgage"] = a[1]
			return "zillow.fetch", p, ""
		}
		return "zillow.available", p, ""
	case "call":
		if len(a) < 1 {
			return "", nil, "call <method> [json-params]"
		}
		method := a[0]
		var params map[string]any
		if len(a) >= 2 {
			if err := json.Unmarshal([]byte(a[1]), &params); err != nil {
				return "", nil, "json-params is not valid JSON: " + err.Error()
			}
		}
		if params == nil {
			params = map[string]any{}
		}
		return method, params, ""
	}
	return "", nil, "unknown command: " + cmd
}

func mapMortgage(a []string) (string, map[string]any, string) {
	p := map[string]any{}
	if len(a) == 0 || a[0] == "list" {
		return "mortgages.list", p, ""
	}
	switch a[0] {
	case "summary":
		if len(a) < 2 {
			return "", nil, "mortgage summary <id>"
		}
		p["id"] = a[1]
		return "mortgages.summary", p, ""
	case "schedule":
		if len(a) < 2 {
			return "", nil, "mortgage schedule <id>"
		}
		p["id"] = a[1]
		return "mortgages.schedule", p, ""
	case "delete":
		p["id"] = a[1]
		return "mortgages.delete", p, ""
	case "detect-payment":
		p["mortgage"] = a[1]
		return "mortgages.detectPayment", p, ""
	case "mark-payment":
		if len(a) < 3 {
			return "", nil, "mortgage mark-payment <txn> <mortgage-id>"
		}
		p["transaction"] = a[1]
		p["mortgage"] = a[2]
		return "mortgages.markPayment", p, ""
	case "unlink-payment":
		p["transaction"] = a[1]
		return "mortgages.unlinkPayment", p, ""
	case "add-rate":
		if len(a) < 4 {
			return "", nil, "mortgage add-rate <mortgage> <date-epoch> <annual-rate>"
		}
		p["mortgage"] = a[1]
		p["date"] = atoi64(a[2])
		p["annual_rate"] = atof(a[3])
		return "mortgages.addRate", p, ""
	case "add-valuation":
		if len(a) < 4 {
			return "", nil, "mortgage add-valuation <mortgage> <date-epoch> <value> [--source S]"
		}
		p["mortgage"] = a[1]
		p["date"] = atoi64(a[2])
		p["value"] = atof(a[3])
		if v, ok := flagVal(a, "--source"); ok {
			p["source"] = v
		}
		return "mortgages.addValuation", p, ""
	case "add-manual":
		if len(a) < 4 {
			return "", nil, "mortgage add-manual <mortgage> <date-epoch> <amount> [--note N]"
		}
		p["mortgage"] = a[1]
		p["date"] = atoi64(a[2])
		p["amount"] = atof(a[3])
		if v, ok := flagVal(a, "--note"); ok {
			p["note"] = v
		}
		return "mortgages.addManual", p, ""
	case "upsert":
		if len(a) < 2 {
			return "", nil, "mortgage upsert '<json>'"
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(a[1]), &m); err != nil {
			return "", nil, "mortgage json is invalid: " + err.Error()
		}
		return "mortgages.upsert", m, ""
	}
	return "", nil, "unknown mortgage action: " + a[0]
}

// ---- serve --------------------------------------------------------------

func runServe(h *rpc.Handler, a []string, demoSource string) {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	httpAddr, http := flagVal(a, "--http")
	if http {
		fmt.Fprintf(os.Stderr, "phinny serving JSON-RPC on http://%s\n", httpAddr)
		if err := h.ServeHTTP(ctx, httpAddr); err != nil {
			fail("serve", err.Error())
		}
		return
	}
	// Default + explicit --stdio: speak JSON-RPC over stdin/stdout.
	if err := h.ServeStdio(ctx, os.Stdin, os.Stdout); err != nil {
		// EOF is a normal shutdown.
		os.Exit(0)
	}
}

// ---- helpers ------------------------------------------------------------

func has(a []string, flag string) bool {
	for _, x := range a {
		if x == flag {
			return true
		}
	}
	return false
}

func flagVal(a []string, flag string) (string, bool) {
	for i, x := range a {
		if x == flag && i+1 < len(a) {
			return a[i+1], true
		}
		if strings.HasPrefix(x, flag+"=") {
			return strings.TrimPrefix(x, flag+"="), true
		}
	}
	return "", false
}

func atoi64(s string) int64 { n, _ := strconv.ParseInt(s, 10, 64); return n }
func atof(s string) float64 { f, _ := strconv.ParseFloat(s, 64); return f }

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func fail(code, msg string) {
	failErr(&rpc.Error{Code: code, Message: msg})
}

func failErr(e *rpc.Error) {
	enc := json.NewEncoder(os.Stderr)
	enc.SetIndent("", "  ")
	_ = enc.Encode(map[string]any{"error": e})
	os.Exit(1)
}

func usage() {
	fmt.Print(`phinny - Phinny's headless finance engine (SimpleFIN sync, categorization,
transfers, Apple Card import, mortgage math). Drives ~/.phinny/phinny.sqlite.

USAGE
  phinny [--db PATH] [--demo --demo-source PATH] <command> [args]

COMMON COMMANDS
  status                          Mode, connection, counts, Chrome availability
  connect <setup-token>           Claim a SimpleFIN token + first sync
  disconnect                      Forget the SimpleFIN connection
  sync [--force]                  Sync from SimpleFIN (respect ~24/day budget)
  import <file>                   Import an Apple Card export (CSV/OFX/QFX/QBO)
  dashboard                       Summary cards + chart series
  accounts                        List accounts
  accounts hide|show <id>         Hide/show an account on the dashboard
  transactions [--limit N] [--account ID] [--since EPOCH]
  categories                      List categories
  categories add <name> [--color #HEX]
  categories rename <id> <name>   |  categories delete <id>
  categorize set <txn> [cat]      Set/clear a merchant's category (applies to similar)
  categorize toggle <txn> <cat>   |  categorize clear <txn>
  categorize manual|auto <txn> <cat> [--start E] [--end E]
  transfer mark|unmark <txn>      |  transfer detect
  config get | config set [--min-interval-hours N] [--history-days N]

MORTGAGE
  mortgage list|summary <id>|schedule <id>|delete <id>
  mortgage detect-payment <id>    |  mortgage mark-payment <txn> <id>
  mortgage add-rate|add-valuation|add-manual <id> <date-epoch> <num> ...
  mortgage upsert '<json>'        Create/update from a JSON object

ZILLOW (needs Google Chrome installed - a peer dependency)
  zillow status                   Whether Chrome is available
  zillow fetch <mortgage-id>      Look up + store today's Zestimate

DAEMON (used by the macOS app; also for persistent agents)
  serve [--stdio]                 JSON-RPC over stdin/stdout (default)
  serve --http 127.0.0.1:PORT     JSON-RPC over loopback HTTP

LOW-LEVEL
  call <method> ['<json-params>'] Invoke any RPC method directly
  methods                         List every RPC method

All output is JSON. Errors print {"error":{code,message}} to stderr (exit 1).
`)
}
