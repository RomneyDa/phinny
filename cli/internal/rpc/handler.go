// Package rpc is the single command dispatch shared by the one-shot CLI and the
// long-running daemon (stdio + http). A method name plus JSON params maps to a
// service call and a JSON-serializable result, so agents get the exact same
// surface whether they shell out to `phinny <cmd>` or speak JSON-RPC to
// `phinny serve`.
package rpc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/config"
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/service"
	"github.com/RomneyDa/phinny/cli/internal/zillow"
)

// Error is a structured failure with a machine-readable code (mirrors JSON-RPC
// error objects). Code "" defaults to "error".
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

func newErr(code, msg string) *Error {
	if code == "" {
		code = "error"
	}
	return &Error{Code: code, Message: msg}
}

func wrap(err error) *Error {
	if err == nil {
		return nil
	}
	if ze, ok := err.(*zillow.Error); ok {
		return &Error{Code: ze.Code, Message: ze.Message}
	}
	return &Error{Code: "error", Message: err.Error()}
}

// Handler dispatches methods against a Service.
type Handler struct {
	Svc *service.Service
}

// Methods lists every supported method name (for help/discovery).
func Methods() []string {
	ms := make([]string, 0, len(methodDocs))
	for m := range methodDocs {
		ms = append(ms, m)
	}
	sort.Strings(ms)
	return ms
}

// methodDocs documents each method (also used to generate CLI help).
var methodDocs = map[string]string{
	"status":                  "Current mode, connection, counts, and Chrome availability.",
	"state":                   "One-shot full snapshot (raw arrays + dashboard + mortgage summaries) used by the app.",
	"dashboard":               "Summary cards + monthly flow + top spending series.",
	"accounts.list":           "List accounts.",
	"accounts.hide":           "Hide/show an account on the dashboard. params: {id, hidden}",
	"transactions.list":       "List transactions. params: {limit?, account?, since?}",
	"categories.list":         "List spending categories.",
	"categories.add":          "Create a category. params: {name, color?}",
	"categories.upsert":       "Create/update a category (client-supplied id). params: {category object}",
	"categories.update":       "Edit a category. params: {id, name?, color?, is_transfer?}",
	"categories.delete":       "Delete a category. params: {id}",
	"categorize.set":          "Set the only category for a merchant. params: {transaction, category?}",
	"categorize.toggle":       "Toggle a category for a merchant. params: {transaction, category}",
	"categorize.clear":        "Clear all categories for a merchant. params: {transaction}",
	"categorize.manual":       "Add a manual (optionally windowed) link. params: {transaction, category, start?, end?}",
	"categorize.auto":         "Add an auto link (respects manual). params: {transaction, category, start?, end?}",
	"categorize.removeLink":   "Remove one expense-category link. params: {id}",
	"transfers.mark":          "Mark a transaction as a transfer. params: {transaction}",
	"transfers.unmark":        "Mark a transaction as NOT a transfer. params: {transaction}",
	"transfers.detect":        "Auto-detect transfer pairs. Returns count added.",
	"sync":                    "Sync from SimpleFIN (rate-limited). params: {force?}",
	"connect":                 "Claim a setup token + first sync. params: {token}",
	"disconnect":              "Forget the SimpleFIN connection.",
	"import":                  "Import an Apple Card statement. params: {path} or {data_base64, filename}",
	"config.get":              "Read config.yaml settings.",
	"config.set":              "Update settings. params: {min_interval_hours?, history_days?}",
	"mortgages.list":          "List mortgages.",
	"mortgages.upsert":        "Create/update a mortgage. params: {mortgage object}",
	"mortgages.delete":        "Delete a mortgage. params: {id}",
	"mortgages.summary":       "Headline numbers for a mortgage. params: {id, as_of?}",
	"mortgages.schedule":      "Full amortization schedule. params: {id}",
	"mortgages.addRate":       "Add a rate change. params: {mortgage, date, annual_rate}",
	"mortgages.addValuation":  "Add a home valuation. params: {mortgage, date, value, source?}",
	"mortgages.saveValuation": "Upsert a valuation by id (edit/drag-commit). params: {valuation object}",
	"mortgages.addManual":     "Add an extra-principal payment. params: {mortgage, date, amount, note?}",
	"mortgages.deleteChild":   "Delete a mortgage child row. params: {table, id}",
	"mortgages.markPayment":   "Mark a txn as a mortgage's payment. params: {transaction, mortgage}",
	"mortgages.unlinkPayment": "Unlink a payment txn. params: {transaction}",
	"mortgages.detectPayment": "Suggest a recurring payment. params: {mortgage}",
	"mortgages.applyPayment":  "Apply a detected payment. params: {mortgage, payee, amount}",
	"zillow.fetch":            "Fetch + store a Zestimate (needs Chrome). params: {mortgage}",
	"zillow.available":        "Whether a Chromium browser is installed.",
}

// Handle dispatches one method call.
func (h *Handler) Handle(ctx context.Context, method string, raw json.RawMessage) (any, *Error) {
	p := func(v any) *Error {
		if len(raw) == 0 || string(raw) == "null" {
			return nil
		}
		if err := json.Unmarshal(raw, v); err != nil {
			return newErr("bad_params", err.Error())
		}
		return nil
	}
	svc := h.Svc

	switch method {
	case "status":
		return h.status(), nil

	case "dashboard":
		d, err := svc.Dashboard()
		return d, wrap(err)

	case "state":
		st, err := svc.FullState()
		return st, wrap(err)

	case "accounts.list":
		a, err := svc.DB().Accounts()
		return nonNil(a, []model.Account{}), wrap(err)

	case "accounts.hide":
		var in struct {
			ID     string `json:"id"`
			Hidden bool   `json:"hidden"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.SetAccountHidden(in.ID, in.Hidden))

	case "transactions.list":
		var in struct {
			Limit   int    `json:"limit"`
			Account string `json:"account"`
			Since   *int64 `json:"since"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		txns, err := svc.DB().Transactions()
		if err != nil {
			return nil, wrap(err)
		}
		out := make([]model.Transaction, 0, len(txns))
		for _, t := range txns {
			if in.Account != "" && t.AccountID != in.Account {
				continue
			}
			if in.Since != nil && t.Posted < *in.Since {
				continue
			}
			out = append(out, t)
			if in.Limit > 0 && len(out) >= in.Limit {
				break
			}
		}
		return out, nil

	case "categories.list":
		c, err := svc.DB().Categories()
		return nonNil(c, []model.SpendCategory{}), wrap(err)

	case "categories.add":
		var in struct {
			Name  string `json:"name"`
			Color string `json:"color"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		if in.Name == "" {
			return nil, newErr("bad_params", "name is required")
		}
		c, err := svc.AddCategory(in.Name, in.Color)
		return c, wrap(err)

	case "categories.upsert":
		var in model.SpendCategory
		if e := p(&in); e != nil {
			return nil, e
		}
		if in.ID == "" {
			in.ID = "" // let the service assign via add path
			c, err := svc.AddCategory(in.Name, in.ColorHex)
			return c, wrap(err)
		}
		if in.CreatedAt == 0 {
			in.CreatedAt = time.Now().Unix()
		}
		return in, wrap(svc.UpdateCategory(in))

	case "categories.update":
		var in struct {
			ID         string  `json:"id"`
			Name       *string `json:"name"`
			Color      *string `json:"color"`
			IsTransfer *bool   `json:"is_transfer"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		cats, err := svc.DB().Categories()
		if err != nil {
			return nil, wrap(err)
		}
		var cur *model.SpendCategory
		for i := range cats {
			if cats[i].ID == in.ID {
				cur = &cats[i]
				break
			}
		}
		if cur == nil {
			return nil, newErr("not_found", "category not found: "+in.ID)
		}
		if in.Name != nil {
			cur.Name = *in.Name
		}
		if in.Color != nil {
			cur.ColorHex = *in.Color
		}
		if in.IsTransfer != nil {
			cur.IsTransfer = *in.IsTransfer
		}
		return *cur, wrap(svc.UpdateCategory(*cur))

	case "categories.delete":
		var in struct {
			ID string `json:"id"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.DeleteCategory(in.ID))

	case "categorize.set":
		var in struct {
			Transaction string `json:"transaction"`
			Category    string `json:"category"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.SetCategory(in.Transaction, in.Category))

	case "categorize.toggle":
		var in struct {
			Transaction string `json:"transaction"`
			Category    string `json:"category"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.ToggleCategory(in.Transaction, in.Category))

	case "categorize.clear":
		var in struct {
			Transaction string `json:"transaction"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.ClearCategories(in.Transaction))

	case "categorize.manual":
		var in struct {
			Transaction string `json:"transaction"`
			Category    string `json:"category"`
			Start       *int64 `json:"start"`
			End         *int64 `json:"end"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.AddManualLink(in.Transaction, in.Category, in.Start, in.End))

	case "categorize.auto":
		var in struct {
			Transaction string `json:"transaction"`
			Category    string `json:"category"`
			Start       *int64 `json:"start"`
			End         *int64 `json:"end"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.AutoAssign(in.Transaction, in.Category, in.Start, in.End))

	case "categorize.removeLink":
		var in struct {
			ID string `json:"id"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.RemoveLink(in.ID))

	case "transfers.mark":
		var in struct {
			Transaction string `json:"transaction"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.MarkAsTransfer(in.Transaction))

	case "transfers.unmark":
		var in struct {
			Transaction string `json:"transaction"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.MarkNotTransfer(in.Transaction))

	case "transfers.detect":
		n, err := svc.AutoDetectTransfers()
		return countResult{Added: n}, wrap(err)

	case "sync":
		var in struct {
			Force bool `json:"force"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		if err := svc.Sync(in.Force); err != nil {
			return nil, wrap(err)
		}
		return h.status(), nil

	case "connect":
		var in struct {
			Token string `json:"token"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		if in.Token == "" {
			return nil, newErr("bad_params", "token is required")
		}
		if err := svc.Connect(in.Token); err != nil {
			return nil, wrap(err)
		}
		return h.status(), nil

	case "disconnect":
		if err := svc.Disconnect(); err != nil {
			return nil, wrap(err)
		}
		return h.status(), nil

	case "import":
		var in struct {
			Path     string `json:"path"`
			DataB64  string `json:"data_base64"`
			Filename string `json:"filename"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		if in.Path != "" {
			r, err := svc.ImportStatementFile(in.Path)
			return r, wrap(err)
		}
		if in.DataB64 != "" {
			data, err := base64.StdEncoding.DecodeString(in.DataB64)
			if err != nil {
				return nil, newErr("bad_params", "data_base64 is not valid base64")
			}
			name := in.Filename
			if name == "" {
				name = "statement.csv"
			}
			r, err := svc.ImportStatement(data, name)
			return r, wrap(err)
		}
		return nil, newErr("bad_params", "provide path or data_base64")

	case "config.get":
		return svc.Config(), nil

	case "config.set":
		var in struct {
			MinIntervalHours *int `json:"min_interval_hours"`
			HistoryDays      *int `json:"history_days"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		cfg := svc.Config()
		if in.MinIntervalHours != nil {
			cfg.Sync.MinIntervalHours = *in.MinIntervalHours
		}
		if in.HistoryDays != nil {
			cfg.Sync.HistoryDays = *in.HistoryDays
		}
		if err := svc.SetConfig(cfg); err != nil {
			return nil, wrap(err)
		}
		return svc.Config(), nil

	case "mortgages.list":
		m, err := svc.DB().Mortgages()
		return nonNil(m, []model.Mortgage{}), wrap(err)

	case "mortgages.upsert":
		var in model.Mortgage
		if e := p(&in); e != nil {
			return nil, e
		}
		m, err := svc.UpsertMortgage(in)
		return m, wrap(err)

	case "mortgages.delete":
		var in struct {
			ID string `json:"id"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.DeleteMortgage(in.ID))

	case "mortgages.summary":
		var in struct {
			ID   string `json:"id"`
			AsOf *int64 `json:"as_of"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		asOf := time.Now()
		if in.AsOf != nil {
			asOf = time.Unix(*in.AsOf, 0)
		}
		sum, err := svc.MortgageSummary(in.ID, asOf)
		return sum, wrap(err)

	case "mortgages.schedule":
		var in struct {
			ID string `json:"id"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		pts, err := svc.MortgageSchedule(in.ID)
		return pts, wrap(err)

	case "mortgages.addRate":
		var in struct {
			Mortgage   string  `json:"mortgage"`
			Date       int64   `json:"date"`
			AnnualRate float64 `json:"annual_rate"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.AddRateChange(in.Mortgage, in.Date, in.AnnualRate))

	case "mortgages.saveValuation":
		var in model.HomeValuation
		if e := p(&in); e != nil {
			return nil, e
		}
		if in.ID == "" {
			return nil, newErr("bad_params", "valuation id is required")
		}
		return okResult{OK: true}, wrap(svc.DB().SaveValuation(in))

	case "mortgages.addValuation":
		var in struct {
			Mortgage string  `json:"mortgage"`
			Date     int64   `json:"date"`
			Value    float64 `json:"value"`
			Source   *string `json:"source"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.AddValuation(in.Mortgage, in.Date, in.Value, in.Source))

	case "mortgages.addManual":
		var in struct {
			Mortgage string  `json:"mortgage"`
			Date     int64   `json:"date"`
			Amount   float64 `json:"amount"`
			Note     *string `json:"note"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.AddManualTxn(in.Mortgage, in.Date, in.Amount, in.Note))

	case "mortgages.deleteChild":
		var in struct {
			Table string `json:"table"`
			ID    string `json:"id"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.DeleteMortgageChild(in.Table, in.ID))

	case "mortgages.markPayment":
		var in struct {
			Transaction string `json:"transaction"`
			Mortgage    string `json:"mortgage"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		n, err := svc.MarkAsPayment(in.Transaction, in.Mortgage)
		return countResult{Added: n}, wrap(err)

	case "mortgages.unlinkPayment":
		var in struct {
			Transaction string `json:"transaction"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.UnlinkPayment(in.Transaction))

	case "mortgages.detectPayment":
		var in struct {
			Mortgage string `json:"mortgage"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		sug, err := svc.DetectPayment(in.Mortgage)
		return sug, wrap(err)

	case "mortgages.applyPayment":
		var in struct {
			Mortgage string  `json:"mortgage"`
			Payee    string  `json:"payee"`
			Amount   float64 `json:"amount"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		return okResult{OK: true}, wrap(svc.ApplyDetectedPayment(in.Mortgage, in.Payee, in.Amount))

	case "zillow.available":
		return map[string]any{"available": svc.ZillowAvailable(), "install_url": zillow.ChromeInstallURL}, nil

	case "zillow.fetch":
		var in struct {
			Mortgage string `json:"mortgage"`
		}
		if e := p(&in); e != nil {
			return nil, e
		}
		res, err := svc.FetchZillowValuation(ctx, in.Mortgage)
		return res, wrap(err)

	default:
		return nil, newErr("unknown_method", "unknown method: "+method)
	}
}

// ---- result shapes ------------------------------------------------------

type okResult struct {
	OK bool `json:"ok"`
}
type countResult struct {
	Added int `json:"added"`
}

// StatusResult is the snapshot returned by `status`.
type StatusResult struct {
	Mode            string  `json:"mode"`
	Connected       bool    `json:"connected"`
	ImportOnly      bool    `json:"import_only"`
	Writable        bool    `json:"writable"`
	LastSync        *int64  `json:"last_sync"`
	Accounts        int     `json:"accounts"`
	Transactions    int     `json:"transactions"`
	Mortgages       int     `json:"mortgages"`
	ChromeAvailable bool    `json:"chrome_available"`
	Config          config.Config `json:"config"`
}

func (h *Handler) status() StatusResult {
	svc := h.Svc
	st := StatusResult{
		Mode:            string(svc.Mode()),
		Connected:       svc.Connected(),
		ImportOnly:      svc.IsImportOnly(),
		Writable:        svc.Writable(),
		ChromeAvailable: svc.ZillowAvailable(),
		Config:          svc.Config(),
	}
	if last := svc.LastSync(); last != nil {
		u := last.Unix()
		st.LastSync = &u
	}
	if a, err := svc.DB().Accounts(); err == nil {
		st.Accounts = len(a)
	}
	if n, err := svc.DB().TransactionCount(); err == nil {
		st.Transactions = n
	}
	if m, err := svc.DB().Mortgages(); err == nil {
		st.Mortgages = len(m)
	}
	return st
}

// nonNil returns fallback when v is a nil slice (so JSON shows [] not null).
func nonNil[T any](v []T, fallback []T) []T {
	if v == nil {
		return fallback
	}
	return v
}

// DescribeMethods returns method -> doc, sorted for help output.
func DescribeMethods() string {
	ms := Methods()
	out := ""
	for _, m := range ms {
		out += fmt.Sprintf("  %-26s %s\n", m, methodDocs[m])
	}
	_ = os.Stdout
	return out
}
