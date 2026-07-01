# AGENTS.md

Guidance for coding agents (and humans) working on Phinny. Keep it simple - that's the whole point of this codebase.

## What Phinny is

A native macOS SwiftUI app that charts your income/spending, backed by a headless **Go engine** (`phinny`) that owns all the real work: SimpleFIN sync, the local SQLite database, Apple Card import, categorization, transfer detection, mortgage math, and Zillow lookups. No backend server, no telemetry, no web view.

The Go engine is also a standalone **CLI usable by any agent**: every feature in the app is a `phinny` subcommand (or JSON-RPC method). The app is a thin wrapper - it launches `phinny serve --stdio` once and drives it over a pipe.

```
SwiftUI app  --stdio JSON-RPC--+
                               +--> phinny (Go engine) --> ~/.phinny/phinny.sqlite
any agent (CLI / HTTP)  -------+
```

This split means the app and agents share one code path and one database. See `cli/README.md` for the full CLI surface.

## Project layout

```
project.yml                 XcodeGen spec - the source of truth for the Xcode project
cli/                        The phinny Go engine (module github.com/RomneyDa/phinny/cli)
  cmd/phinny/main.go        CLI dispatch + `serve` daemon (stdio / http)
  internal/model            Pure domain types (shared, no I/O)
  internal/store            SQLite (modernc.org/sqlite, WAL); GRDB-compatible migrations
  internal/simplefin        SimpleFIN claim + fetch (the ONLY banking network code)
  internal/importer         Apple Card CSV/OFX/QFX/QBO parser (pure)
  internal/analytics        transactions -> chart series (pure)
  internal/transfers        offsetting cross-account pair detection (pure)
  internal/mortgage         amortization engine + payment detection (pure)
  internal/zillow           Zestimate scrape via headless Chrome (chromedp; PEER dep)
  internal/keychain         SimpleFIN access URL in the macOS Keychain (via `security`)
  internal/config           ~/.phinny paths + config.yaml
  internal/service          orchestration (the AppState logic): bootstrap, sync, import,
                            categorize, transfers, mortgages, FullState snapshot
  internal/rpc              one dispatch shared by the CLI and the daemon (stdio + http)
Sources/                    The SwiftUI app - now a thin client over the engine:
  PhinnyApp.swift           @main App + window
  PhinnyDaemon.swift        launches `phinny serve --stdio`, line-delimited JSON-RPC
  AppState.swift            @MainActor store: loads a FullState snapshot per change,
                            routes every mutation through the daemon
  Models / Analytics / Mortgage / Categories
                            Codable shells decoded from the engine's JSON + small pure
                            presentation helpers (category resolution, normalize, the
                            live payment formula). The heavy logic lives in the engine.
  Views/                    SwiftUI: unchanged consumers of AppState
Resources/                  Entitlements, Assets.xcassets, phinny-demo.sqlite, Info.plist
                            (build-app.sh also embeds the built phinny binary here)
archive/                    The pre-Go Swift engine, kept for reference (not built)
scripts/                    run.sh, build-app.sh, build-signed-local.sh, ...
docs/                       Single-page static docs site
.github/workflows/          release.yml (Go + build -> sign -> notarize -> Release)
```

## Modes

The **engine** picks the mode (`service.bootstrap`), and the app reflects it:

- **Demo** (no account, no real DB): copies the bundled `phinny-demo.sqlite` and opens it. No network. Default state. The app passes the bundled DB path via `serve --demo-source <path>`.
- **Connected** (access URL in Keychain): reads/writes `~/.phinny/phinny.sqlite` and syncs.
- **Import-only** (no access URL, but a real DB exists from an Apple Card import): reads/writes the real DB but has nothing to sync, so the dashboard hides "Sync Now".

In Debug, a `SIMPLEFIN_TOKEN` from `.env` makes the app call `connect` on first launch (run via `./scripts/run.sh`). Launch-time auto-sync is stale-only (the app gates it from the FullState snapshot's `last_sync` + `config.min_interval_hours`).

The SQLite schema is shared with the historical GRDB database: the Go migrator uses the same `grdb_migrations` table and identifiers (v1..v9), so it opens existing user databases (and the committed demo DB) without re-creating tables.

> **Known follow-up:** the demo-data synthesizer (old `DemoData.swift`) is not yet ported to Go, so `scripts/generate-demo-db.sh` now only validates the committed `Resources/phinny-demo.sqlite`. A `phinny gen-demo` command would restore one-command regeneration.

## Build & run

```bash
./scripts/run.sh                                   # build + launch (passes .env)
./scripts/build-app.sh && open dist/Phinny.app     # dev-signed build, no launch
xcodegen generate && open Phinny.xcodeproj         # iterate in Xcode (set PHINNY_BIN to a go-built engine)
( cd cli && go build ./... && go test ./... )      # build + test the Go engine
./scripts/generate-demo-db.sh                      # validate the bundled demo DB
```

`build-app.sh` cross-compiles the `phinny` engine (universal, pure Go / no cgo) and embeds it at `Phinny.app/Contents/Resources/phinny`; `codesign --deep` signs it. The app finds it via `Bundle.main`, or via the `PHINNY_BIN` env override when iterating in Xcode (point it at `cli`'s `go build` output so you don't rebuild the app each time).

The `.xcodeproj` and `Resources/Info.plist` are **generated** (git-ignored). Never hand-edit them - change `project.yml`.

> **XcodeGen gotcha:** there is no separate `resources:` target key (it is silently ignored). List resources (`.xcassets`, `.sqlite`, etc.) under `sources:` - XcodeGen auto-categorizes them into the Copy Bundle Resources phase by file type.

Requirements: macOS 14+, Xcode 26+, and [XcodeGen](https://github.com/yonsson/XcodeGen) (`brew install xcodegen`). `swift scripts/generate-icon.swift` regenerates the procedurally-drawn app icon.

### Testing with real data

To point a dev build at your real account without pasting a token through the UI each time, copy `.env.example` to `.env` and set your token:

```bash
cp .env.example .env
echo 'SIMPLEFIN_TOKEN=your-setup-token' >> .env
./scripts/run.sh    # Debug build auto-connects on first launch (one real sync)
```

The token is single-use: after the first connect the access URL is stored in your Keychain and `.env` is ignored. `run.sh` launches the binary directly (not via `open`) so the variable reaches the app. Respect the ~24 syncs/day budget (see Hard rule 1).

## Hard rules

1. **Respect the SimpleFIN budget (~24 requests/day).** Do NOT add code paths that sync on a timer, on every launch, or in a loop. Auto-sync is stale-only (`service.ShouldAutoSync`; the app gates the launch sync from the FullState snapshot). When testing, use **demo mode** (`phinny --demo --demo-source <db>` / the app default, no network) - never spam a real token. Aim for 1-2 real syncs, then work against the cached SQLite data.
2. **Credentials only in the Keychain.** The access URL embeds bank-read credentials. It must never be written to `config.yaml`, logged, or committed. Use `internal/keychain` (the engine; the app no longer touches the Keychain directly).
3. **One source of truth.** All persistence and mutation lives in the Go engine (`internal/service`). The app's `AppState` is a read-through/RPC client; Views are read-only consumers of `AppState`; keep them dumb.
4. **Keep the pure packages pure.** `internal/analytics`, `internal/importer`, `internal/transfers`, and the `internal/mortgage` math do no I/O, so they stay trivially testable (`go test ./...`).
5. **`internal/simplefin` is the only banking network code.** Don't scatter HTTP calls elsewhere. (`internal/zillow` is the only other network path, and it is opt-in + behind the Chrome peer dependency.)
6. **No em-dashes. Ever.** Do not use em-dashes (the long dash) or en-dashes anywhere: not in docs, READMEs, UI copy, commit messages, code comments, or strings. Use a plain hyphen, a comma, parentheses, or two sentences instead. This is a hard style rule for the whole repo.

## Conventions

- Swift 5 language mode, complete strict concurrency (see `project.yml` for the macOS 26 runtime workaround note).
- Money follows the SimpleFIN sign convention: negative = spending, positive = income.
- Dates from SimpleFIN are epoch seconds.
- New settings → add to `Config.Sync` (YAML). New secrets → `Keychain.swift`. New stored data → a GRDB migration in `Database.swift` (append a new `registerMigration`, never edit an existing one).
- Mortgage math source of truth: balance/equity/payoff always come from `MortgageEngine` (loan terms), never from linked payment amounts. Linked payments are display-only and feed the escrow back-calculation (actual payment − scheduled P&I). Don't let a real payment amount drive the amortization.
- Categorization: a `SpendCategory` is global (user- or future-AI-created). An `expense_category` row links one transaction to one category, with `isAuto` (manual vs auto) and an optional effective window (`startDate`/`endDate`, both nil = always). The Swift type is `SpendCategory`, not `Category` (the bare name collides with a clang-imported C symbol). Conflict rule: two links conflict only when `transactionId` AND `categoryId` match AND their windows overlap, so an expense can hold several categories and the same expense+category can repeat across non-overlapping windows. Manual links are never overridden by auto-categorization: `AppState.autoAssign` skips any transaction that already has a manual link. Resolution for charts/chips prefers manual over auto, then newest. The quick manual actions (`setCategory`, `toggleCategory`, `clearCategories`) apply to every similar transaction (same account + normalized title, via `AppState.similarTransactions`), so tagging a merchant once tags all of its transactions; the advanced/windowed path (`addManualLink` / `removeLink`) and transfer marking stay single-transaction.
- Apple Card import: Apple blocks aggregators (Plaid/MX/SimpleFIN) from Apple Card, so it is never synced. `StatementImporter` (pure, like `Analytics`) parses a Wallet export (CSV/OFX/QFX/QBO) into a `SimpleFINClient.FetchResult` that `AppState.importStatement(from:)` writes through the same `AppDatabase.replace(...)` upsert as a sync, so categorization, transfers, and mortgage linking all work on imported rows with no schema change. Everything lands as one synthetic account (`StatementImporter.accountId` = "applecard-import", a constant so re-imports update the same account, never deleted by a sync). Re-import is idempotent: OFX rows key on `FITID`, CSV rows (no id) on a deterministic FNV-1a content hash (never Swift's randomized `Hasher`). Sign convention is normalized to SimpleFIN's (negative = spending): OFX `TRNAMT` is already debit-negative; Apple's CSV shows purchases as positive, so the CSV path negates. Apple only exports closed monthly statements, so the current cycle never appears (an inherently monthly, manual import).
- Transfers: a `category.isTransfer` flag means "money moved between your own accounts" so those transactions are excluded from income/spending. There is one permanent, hard-coded Transfer category (id `SpendCategory.transferId` = "transfer", seeded by migration v6, not deletable). Marking a transaction AS a transfer reuses the normal manual `ExpenseCategory` link to that category. Marking it NOT a transfer drops any transfer links and records a `transfer_exclusion` row so auto-detection never re-tags it. `TransferDetection` (pure) finds offsetting cross-account pairs within `defaultWindowDays` (3); `AppState.autoDetectTransfers()` runs it after every sync (and from the Categories view) and auto-links both legs, respecting manual links and exclusions. Analytics exclude transfers via `AppState.spendingTransactions`, keeping `Analytics` pure (it only ever sees pre-filtered transactions). The transaction list still shows transfers with their chip.

## Common tasks

- **Add a chart:** add a pure aggregation to `Analytics.swift`, expose it via a computed property on `AppState`, render it in a new view under `Views/`, drop it into `DashboardView`.
- **Change the schema:** append a new migration in `Database.migrator`; update the `Account`/`Transaction` structs; then regenerate the demo DB with `./scripts/generate-demo-db.sh` and commit it.
- **Tweak the icon:** edit and run `swift scripts/generate-icon.swift`.
- **Change demo data:** edit `DemoData.swift`, then `./scripts/generate-demo-db.sh`, then commit `Resources/phinny-demo.sqlite`.

## Verifying changes

`./scripts/build-app.sh` must succeed with zero warnings. Launch (`./scripts/run.sh`) and confirm demo data renders, and that the Connect sheet opens, before committing.

## Release & signing

Local signed/notarized build (needs `.env.signing.local`, see `.env.signing.local.example`):

```bash
cp .env.signing.local.example .env.signing.local   # fill in Apple credentials
./scripts/build-signed-local.sh                     # -> dist/Phinny.dmg + Phinny.zip
```

CI builds, signs, notarizes, and attaches a DMG to a GitHub Release on any `v*` tag (`.github/workflows/release.yml`). Required repo secrets:

| Secret | Meaning |
|---|---|
| `MAC_CSC_LINK` | base64 of the Developer ID Application `.p12` |
| `MAC_CSC_KEY_PASSWORD` | password for that `.p12` |
| `DEVELOPER_ID_APPLICATION` | e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password for notarization |

```bash
git tag v0.1.0 && git push --tags    # triggers the release workflow
```

## Docs site

A self-contained single-page site lives in `docs/` (plain HTML/CSS, no build step). It is published at `dallinromney.com/phinny` by the gateway site (`dr-site-nextjs`), which fetches `docs/` from this repo's `main` at build time (`scripts/fetch-phinny-docs.mjs` -> `public/phinny/`) and serves it as static files. So a push to `main` here, followed by a redeploy of `dr-site-nextjs`, ships the docs. The asset references in `index.html` are absolute (`/phinny/...`) precisely so they resolve under that path; keep them that way.
