# phinny - the Phinny engine + CLI

`phinny` is the headless Go engine behind the Phinny macOS app. It owns
everything: the local SQLite database (`~/.phinny/phinny.sqlite`), SimpleFIN
sync, Apple Card statement import, categorization, transfer detection, the
mortgage amortization math, and Zillow Zestimate lookups.

It is built to be driven by **agents**. Every feature is a subcommand (or a
JSON-RPC method). All output is JSON; errors print `{"error":{code,message}}`
to stderr and exit non-zero.

The macOS app is a thin wrapper: it launches `phinny serve --stdio` and talks to
it over a pipe. Agents can do the same, or just shell out to one-shot commands.

## Build

```bash
cd cli
go build -o phinny ./cmd/phinny     # pure Go, no cgo
go test ./...
```

The app bundles a universal build at `Phinny.app/Contents/Resources/phinny`.

## Data + safety

- Database: `~/.phinny/phinny.sqlite` (WAL; safe for the daemon and one-shot
  CLIs to share). Override with `--db <path>`.
- Settings: `~/.phinny/config.yaml`. Credentials are **never** stored here.
- The SimpleFIN access URL (bank-read credentials) lives in the macOS Keychain.
- **Respect the SimpleFIN budget (~24 requests/day).** Do not loop `sync`. Use
  `--demo` for experimentation (bundled sample data, no network).

```bash
# Safe sandbox: demo data, throwaway home, no network, no real account touched.
phinny --demo --demo-source /path/to/phinny-demo.sqlite status
```

## One-shot commands

```
phinny status                          Mode, connection, counts, Chrome availability
phinny connect <setup-token>           Claim a SimpleFIN token + first sync
phinny disconnect                      Forget the SimpleFIN connection
phinny sync [--force]                  Sync from SimpleFIN (rate-limited!)
phinny import <file>                   Import an Apple Card export (CSV/OFX/QFX/QBO)
phinny dashboard                       Summary cards + chart series
phinny accounts                        List accounts
phinny accounts hide|show <id>         Hide/show an account on the dashboard
phinny transactions [--limit N] [--account ID] [--since EPOCH]
phinny categories                      List categories
phinny categories add <name> [--color #HEX]
phinny categories rename <id> <name>   |  phinny categories delete <id>
phinny categorize set <txn> [cat]      Set/clear a merchant's category (applies to similar)
phinny categorize toggle <txn> <cat>   |  phinny categorize clear <txn>
phinny categorize manual|auto <txn> <cat> [--start EPOCH] [--end EPOCH]
phinny transfer mark|unmark <txn>      |  phinny transfer detect
phinny config get | config set [--min-interval-hours N] [--history-days N]

phinny mortgage list|summary <id>|schedule <id>|delete <id>
phinny mortgage detect-payment <id>    |  phinny mortgage mark-payment <txn> <id>
phinny mortgage add-rate|add-valuation|add-manual <id> <date-epoch> <num> ...
phinny mortgage upsert '<json>'        Create/update from a JSON object

phinny zillow status                   Whether Chrome (the peer dependency) is available
phinny zillow fetch <mortgage-id>      Look up + store today's Zestimate

phinny call <method> ['<json-params>'] Invoke any RPC method directly
phinny methods                         List every RPC method
```

Categorization note: `set` / `toggle` / `clear` apply to **every similar
transaction** (same account + normalized merchant), so tagging a merchant once
tags all of its transactions. The windowed `manual` / `auto` path is
single-transaction. Money sign: negative = spending, positive = income.

## Daemon (`serve`)

For a persistent connection (the app uses this; agents can too):

```bash
phinny serve --stdio                   # JSON-RPC over stdin/stdout (default)
phinny serve --http 127.0.0.1:8765     # JSON-RPC over loopback HTTP
phinny serve --stdio --demo-source <db>  # serve bundled demo data
```

Request/response is JSON-RPC-ish, one object per line (stdio) or one POST body
(http):

```json
{"id":1,"method":"transactions.list","params":{"limit":5}}
{"id":1,"result":[ ... ]}
```

```bash
# HTTP example
curl -s localhost:8765 -d '{"method":"dashboard"}'
```

The richest read is `state` (used by the app): one snapshot with every raw array
plus the derived dashboard and per-mortgage summaries/schedules.

## Zillow needs Chrome (peer dependency)

Zestimate lookups drive a real browser via headless Chrome (chromedp). Chrome is
**not bundled**; it is a peer dependency. If no Chromium-family browser is found,
`zillow fetch` returns:

```json
{"error":{"code":"chrome_not_installed","message":"Zillow lookups need Google Chrome ... Install it from https://www.google.com/chrome/ ..."}}
```

Check first with `phinny zillow status`. Override the browser path with
`PHINNY_CHROME_PATH`; force a visible window with `PHINNY_ZILLOW_HEADFUL=1`.

## Architecture

```
cmd/phinny        CLI parsing + serve (stdio/http)
internal/rpc      one dispatch shared by the CLI and the daemon
internal/service  orchestration: bootstrap/mode, sync, import, categorize,
                  transfers, mortgages, FullState snapshot
internal/store    SQLite (modernc.org/sqlite, WAL). GRDB-compatible migrations,
                  so it opens databases created by the historical Swift app.
internal/{model,analytics,importer,transfers,mortgage}   pure, no I/O
internal/{simplefin,zillow,keychain,config}              the I/O edges
```
