# Phinny CLI reference

Full surface for the `phinny` engine. All output is JSON; errors print
`{"error":{"code":...,"message":...}}` to stderr with a non-zero exit.

## Global flags

- `--db <path>` - use a specific database file (default `~/.phinny/phinny.sqlite`).
- `--demo --demo-source <path>` - open bundled demo data (no network, safe for testing).

## One-shot commands

```
status                          Mode, connection, counts, Chrome availability
dashboard                       Summary cards + chart series
connect <setup-token>           Claim a SimpleFIN token + first sync (rate-limited)
disconnect                      Forget the SimpleFIN connection
sync [--force]                  Sync from SimpleFIN (RATE-LIMITED, ~24/day budget)
import <file>                   Import an Apple Card export (CSV/OFX/QFX/QBO)

accounts                        List accounts
accounts hide|show <id>         Hide/show an account on the dashboard
transactions [--limit N] [--account ID] [--since EPOCH]

categories                      List categories
categories add <name> [--color #HEX]
categories rename <id> <name>
categories delete <id>
categorize set <txn> [cat]      Set/clear a merchant's category (applies to similar)
categorize toggle <txn> <cat>
categorize clear <txn>
categorize manual|auto <txn> <cat> [--start EPOCH] [--end EPOCH]
categorize remove <link-id>

transfer mark|unmark <txn>
transfer detect

config get
config set [--min-interval-hours N] [--history-days N]

mortgage list|summary <id>|schedule <id>|delete <id>
mortgage detect-payment <id>
mortgage mark-payment <txn> <mortgage-id>
mortgage unlink-payment <txn>
mortgage add-rate <mortgage> <date-epoch> <annual-rate>
mortgage add-valuation <mortgage> <date-epoch> <value> [--source S]
mortgage add-manual <mortgage> <date-epoch> <amount> [--note N]
mortgage upsert '<json>'        Create/update from a JSON object

zillow status                   Whether Chrome (the peer dependency) is available
zillow fetch <mortgage-id>      Look up + store today's Zestimate

call <method> ['<json-params>'] Invoke any RPC method directly
methods                         List every RPC method
```

## Behavior notes

- **Categorize scope:** `set` / `toggle` / `clear` apply to every *similar*
  transaction (same account + normalized merchant), so tagging one merchant tags
  all its transactions. The windowed `manual` / `auto` path is single-transaction.
- **Manual wins:** auto-categorization never overrides a manual tag.
- **Transfers:** `transfer detect` links offsetting cross-account pairs within a
  few days. `transfer unmark` is sticky (auto-detection never re-tags it).
- **Mortgage math source of truth:** balance/equity/payoff come from the loan
  terms via the engine, never from linked payment amounts.
- **Apple Card:** re-importing an overlapping statement is idempotent.

## JSON-RPC (daemon or `call`)

The CLI and the daemon share one dispatch. Request/response is one JSON object
per line (stdio) or one POST body (http):

```json
{"id":1,"method":"transactions.list","params":{"limit":5}}
{"id":1,"result":[ ... ]}
```

```bash
phinny serve --http 127.0.0.1:8765
curl -s localhost:8765 -d '{"method":"dashboard"}'
```

Method names (from `phinny methods`): `status`, `state`, `dashboard`,
`accounts.list`, `accounts.hide`, `transactions.list`, `categories.list`,
`categories.add`, `categories.upsert`, `categories.update`, `categories.delete`,
`categorize.set`, `categorize.toggle`, `categorize.clear`, `categorize.manual`,
`categorize.auto`, `categorize.removeLink`, `transfers.mark`, `transfers.unmark`,
`transfers.detect`, `sync`, `connect`, `disconnect`, `import`, `config.get`,
`config.set`, `mortgages.list`, `mortgages.upsert`, `mortgages.delete`,
`mortgages.summary`, `mortgages.schedule`, `mortgages.addRate`,
`mortgages.addValuation`, `mortgages.saveValuation`, `mortgages.addManual`,
`mortgages.deleteChild`, `mortgages.markPayment`, `mortgages.unlinkPayment`,
`mortgages.detectPayment`, `mortgages.applyPayment`, `zillow.available`,
`zillow.fetch`.

`state` returns one snapshot with every raw array plus the derived dashboard and
per-mortgage summaries/schedules (this is what the macOS app loads per change).

## Chrome peer dependency (Zillow)

Zestimate lookups drive headless Chrome (chromedp); Chrome is not bundled. Check
`phinny zillow status` first. On a missing browser, `zillow fetch` returns
`{"error":{"code":"chrome_not_installed","message":"... Install it from https://www.google.com/chrome/ ..."}}`.
Env overrides: `PHINNY_CHROME_PATH` (browser path), `PHINNY_ZILLOW_HEADFUL=1`
(visible window).
