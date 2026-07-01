---
name: phinny-cli
description: Drive the Phinny finance engine via its `phinny` CLI to read and manage a user's local bank data. Use when the user asks about their Phinny data or personal finances stored in ~/.phinny, mentions SimpleFIN, or wants to list accounts and transactions, categorize spending, detect or mark transfers between their own accounts, import an Apple Card statement, run mortgage amortization/equity/payoff math, look up a Zillow home value, or sync new bank data. Output is JSON, so it is easy to parse and reason over.
compatibility: Requires the `phinny` CLI (install with `go install github.com/RomneyDa/phinny/cli/cmd/phinny@latest`). macOS-oriented - reads credentials from the Keychain via /usr/bin/security, and Zillow lookups need Google Chrome installed.
metadata:
  author: RomneyDa
  version: "1.0"
  homepage: https://github.com/RomneyDa/phinny
---

# Phinny CLI

`phinny` is the headless engine behind the Phinny macOS app. It owns the user's
local finance database (`~/.phinny/phinny.sqlite`): SimpleFIN bank sync, Apple
Card import, categorization, transfer detection, mortgage math, and Zillow home
valuations. Every command prints **JSON** to stdout; errors print
`{"error":{"code":...,"message":...}}` to stderr and exit non-zero.

## Setup

Check it is installed and see the current state:

```bash
phinny status
```

If `phinny` is not found, install it: `go install github.com/RomneyDa/phinny/cli/cmd/phinny@latest` (needs the Go toolchain; the binary lands in `$(go env GOPATH)/bin`). `phinny --help` lists commands; `phinny methods` lists every RPC method.

## Two hard rules

1. **Respect the SimpleFIN request budget (~24/day).** `phinny sync` is the only rate-limited call. NEVER loop it, run it in a timer, or sync "just to be safe." Sync at most once or twice, then work against the cached data. When exploring or testing, use demo mode instead (no network, no real account):

   ```bash
   phinny --demo --demo-source <path-to/phinny-demo.sqlite> status
   ```

2. **Money sign convention:** negative `amount` = spending, positive = income. Transfers between the user's own accounts are excluded from income/spending totals.

## Common tasks

Inspect:

```bash
phinny status                       # mode, connection, counts, Chrome availability
phinny dashboard                    # summary cards + monthly flow + top spending
phinny accounts                     # list accounts
phinny transactions --limit 20      # recent transactions (also --account ID, --since EPOCH)
```

Categorize (tagging a merchant applies to every similar transaction: same account
+ normalized merchant name):

```bash
phinny categories                              # list categories
phinny categories add "Coffee" --color "#AA5500"
phinny categorize set <txn-id> <category-id>   # set the merchant's only category
phinny categorize toggle <txn-id> <category-id># add/remove one category
phinny categorize clear <txn-id>               # remove all
```

Transfers (money moved between the user's own accounts):

```bash
phinny transfer detect                # auto-detect offsetting cross-account pairs
phinny transfer mark <txn-id>         # force-mark as a transfer
phinny transfer unmark <txn-id>       # force-mark as NOT a transfer (sticky)
```

Import an Apple Card statement (Apple blocks SimpleFIN; the user exports a
CSV/OFX/QFX/QBO from Wallet):

```bash
phinny import ~/Downloads/apple-card-statement.csv
```

Sync new bank data (budget! see rule 1):

```bash
phinny sync           # only if data is stale
phinny sync --force   # explicit refresh
```

Mortgages (the engine computes the whole amortization from the loan terms; do not
ask the user to log payments):

```bash
phinny mortgage list
phinny mortgage summary <id>          # balance, equity, payoff, monthly payment
phinny mortgage schedule <id>         # full month-by-month schedule
phinny mortgage detect-payment <id>   # suggest the recurring payment transaction
```

Zillow home value (peer dependency: needs Google Chrome):

```bash
phinny zillow status                  # {"available": true|false, "install_url": ...}
phinny zillow fetch <mortgage-id>     # scrape + store today's Zestimate
```

If Chrome is missing, `zillow fetch` returns `{"error":{"code":"chrome_not_installed",...}}` with an install URL. Tell the user to install Chrome rather than retrying.

## Escape hatch and persistent use

Any RPC method can be called directly, and a persistent daemon avoids re-spawning:

```bash
phinny call <method> '<json-params>'          # e.g. phinny call transactions.list '{"limit":5}'
phinny methods                                 # list every method
phinny serve --stdio                           # JSON-RPC over stdin/stdout (one object per line)
phinny serve --http 127.0.0.1:8765             # JSON-RPC over loopback HTTP
```

For the full command + method reference, JSON-RPC shapes, and the `state`
snapshot the app uses, see [references/commands.md](references/commands.md).
