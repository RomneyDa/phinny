# AGENTS.md

Guidance for coding agents (and humans) working on Phinny. Keep it simple - that's the whole point of this codebase.

## What Phinny is

A native macOS SwiftUI app that pulls bank data from SimpleFIN into a local SQLite database and charts income/spending. No backend, no telemetry, no web view.

## Project layout

```
project.yml                 XcodeGen spec - the source of truth for the Xcode project
Sources/
  PhinnyApp.swift           @main App + window
  AppState.swift            @MainActor ObservableObject - the only place that mutates app state
  SimpleFINClient.swift     SimpleFIN protocol (claim + fetch). The ONLY network code.
  Database.swift            GRDB/SQLite (~/.phinny/phinny.sqlite)
  Keychain.swift            Stores the SimpleFIN access URL (credentials) securely
  Config.swift              ~/.phinny paths + config.yaml (non-sensitive settings)
  Keychain.swift            Stores the SimpleFIN access URL (credentials) securely
  Models.swift              Account, Transaction (GRDB records)
  Analytics.swift           Pure functions: transactions -> chart series
  DemoData.swift            Synthesizes the bundled demo database
  Mortgage/                 MortgageModels, MortgageEngine (pure amortization),
                            MortgageDetection (link/detect payments),
                            ZillowScraper (offscreen WKWebView Zestimate lookup;
                            prefers a pasted homedetails URL over address search)
  Categories/               CategoryModels (SpendCategory + ExpenseCategory link
                            with isAuto flag and optional effective date range;
                            TransferExclusion), TransferDetection (pure: spots
                            offsetting cross-account pairs)
  Views/                    SwiftUI: RootView, MainView (sidebar), Dashboard, Charts,
                            OnboardingView (connect sheet),
                            Mortgage/ (detail, editor, InteractiveHomeValueChart, AddressField),
                            Categories/ (CategoriesView manager, CategoryChip,
                            AssignCategorySheet)
Resources/                  Entitlements, Assets.xcassets (procedural app icon),
                            phinny-demo.sqlite (bundled demo data), generated Info.plist
scripts/                    run.sh, build-app.sh, build-signed-local.sh,
                            generate-icon.swift, generate-demo-db.sh
docs/                       Single-page static docs site
.github/workflows/          release.yml (build -> sign -> notarize -> GitHub Release)
```

## Two modes

- **Demo** (no account connected): opens the bundled `phinny-demo.sqlite`. No network. Default state.
- **Connected** (access URL in Keychain): reads/writes `~/.phinny/phinny.sqlite` and syncs.

`AppState.bootstrap()` chooses the mode. In Debug, a `SIMPLEFIN_TOKEN` from `.env` auto-connects (run via `./scripts/run.sh`).

## Build & run

```bash
./scripts/run.sh                                   # build + launch (passes .env)
./scripts/build-app.sh && open dist/Phinny.app     # dev-signed build, no launch
xcodegen generate && open Phinny.xcodeproj         # iterate in Xcode
./scripts/generate-demo-db.sh                      # rebuild Resources/phinny-demo.sqlite
```

The `.xcodeproj` and `Resources/Info.plist` are **generated** (git-ignored). Never hand-edit them - change `project.yml`.

> **XcodeGen gotcha:** there is no separate `resources:` target key (it is silently ignored). List resources (`.xcassets`, `.sqlite`, etc.) under `sources:` - XcodeGen auto-categorizes them into the Copy Bundle Resources phase by file type.

## Hard rules

1. **Respect the SimpleFIN budget (~24 requests/day).** Do NOT add code paths that sync on a timer, on every launch, or in a loop. Auto-sync is gated by `AppState.shouldAutoSync` (stale-only). When testing, use **demo mode** (the default, bundled sample data, no network) - never spam a real token. Aim for 1-2 real syncs, then work against the cached SQLite data.
2. **Credentials only in the Keychain.** The access URL embeds bank-read credentials. It must never be written to `config.yaml`, logged, or committed. Use `Keychain.swift`.
3. **One source of truth.** All mutable UI state lives in `AppState`. Views are read-only consumers; keep them dumb.
4. **Keep `Analytics` pure.** No I/O there - it makes the aggregations trivially testable and the charts predictable.
5. **`SimpleFINClient` is the only networking.** Don't scatter `URLSession` calls elsewhere.
6. **No em-dashes. Ever.** Do not use em-dashes (the long dash) or en-dashes anywhere: not in docs, READMEs, UI copy, commit messages, code comments, or strings. Use a plain hyphen, a comma, parentheses, or two sentences instead. This is a hard style rule for the whole repo.

## Conventions

- Swift 5 language mode, complete strict concurrency (see `project.yml` for the macOS 26 runtime workaround note).
- Money follows the SimpleFIN sign convention: negative = spending, positive = income.
- Dates from SimpleFIN are epoch seconds.
- New settings → add to `Config.Sync` (YAML). New secrets → `Keychain.swift`. New stored data → a GRDB migration in `Database.swift` (append a new `registerMigration`, never edit an existing one).
- Mortgage math source of truth: balance/equity/payoff always come from `MortgageEngine` (loan terms), never from linked payment amounts. Linked payments are display-only and feed the escrow back-calculation (actual payment − scheduled P&I). Don't let a real payment amount drive the amortization.
- Categorization: a `SpendCategory` is global (user- or future-AI-created). An `expense_category` row links one transaction to one category, with `isAuto` (manual vs auto) and an optional effective window (`startDate`/`endDate`, both nil = always). The Swift type is `SpendCategory`, not `Category` (the bare name collides with a clang-imported C symbol). Conflict rule: two links conflict only when `transactionId` AND `categoryId` match AND their windows overlap, so an expense can hold several categories and the same expense+category can repeat across non-overlapping windows. Manual links are never overridden by auto-categorization: `AppState.autoAssign` skips any transaction that already has a manual link. Resolution for charts/chips prefers manual over auto, then newest.
- Transfers: a `category.isTransfer` flag means "money moved between your own accounts" so those transactions are excluded from income/spending. There is one permanent, hard-coded Transfer category (id `SpendCategory.transferId` = "transfer", seeded by migration v6, not deletable). Marking a transaction AS a transfer reuses the normal manual `ExpenseCategory` link to that category. Marking it NOT a transfer drops any transfer links and records a `transfer_exclusion` row so auto-detection never re-tags it. `TransferDetection` (pure) finds offsetting cross-account pairs within `defaultWindowDays` (3); `AppState.autoDetectTransfers()` runs it after every sync (and from the Categories view) and auto-links both legs, respecting manual links and exclusions. Analytics exclude transfers via `AppState.spendingTransactions`, keeping `Analytics` pure (it only ever sees pre-filtered transactions). The transaction list still shows transfers with their chip.

## Common tasks

- **Add a chart:** add a pure aggregation to `Analytics.swift`, expose it via a computed property on `AppState`, render it in a new view under `Views/`, drop it into `DashboardView`.
- **Change the schema:** append a new migration in `Database.migrator`; update the `Account`/`Transaction` structs; then regenerate the demo DB with `./scripts/generate-demo-db.sh` and commit it.
- **Tweak the icon:** edit and run `swift scripts/generate-icon.swift`.
- **Change demo data:** edit `DemoData.swift`, then `./scripts/generate-demo-db.sh`, then commit `Resources/phinny-demo.sqlite`.

## Verifying changes

`./scripts/build-app.sh` must succeed with zero warnings. Launch (`./scripts/run.sh`) and confirm demo data renders, and that the Connect sheet opens, before committing.
