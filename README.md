<div align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Phinny icon" />
  <h1>Phinny</h1>
  <p><b>An unofficial <a href="https://simplefin.org">SimpleFIN</a> viewer for macOS.</b><br/>Syncs your bank data and shows your income &amp; spending in beautiful native charts.</p>
</div>

---

## What it does

- **Connect once** with a SimpleFIN setup token (or try the built-in demo).
- **Syncs automatically** on launch - but only when the data is stale, to respect SimpleFIN's ~24 requests/day budget.
- **Visualizes** income vs. spending, net cash flow, top spending, and recent transactions with native [Swift Charts](https://developer.apple.com/documentation/charts).
- **Tracks mortgages** without logging every payment: enter the loan, rate, and down payment and Phinny computes the whole amortization, equity, and payoff. Adjust the rate and home value over time, add extra principal payments, and link a real expense as the recurring payment (with historical auto-detection).
- **Categorizes spending** into your own categories: tag any transaction from the dashboard (or scope a tag to a date range), and the Top Spending chart groups by your categories. The data model is built for a future AI auto-categorizer, with a manual-versus-auto flag so your manual tags are never overwritten.
- **Detects transfers** between your own accounts (offsetting amounts a few days apart) and keeps them out of your income and spending totals. A permanent Transfer category does the excluding; you can mark anything as a transfer (or "not a transfer") and your choice always wins over auto-detection.
- **Imports Apple Card** statements that SimpleFIN can't reach. Apple blocks aggregators (Plaid/MX/SimpleFIN) from Apple Card, so Phinny imports the file you export from the iPhone Wallet app (CSV, OFX, QFX, or QBO). It can even run on Apple Card alone, with no SimpleFIN account connected. See [Apple Card import](#apple-card-import).
- **Stores everything locally** - SQLite database in `~/.phinny`, credentials in the macOS Keychain. Nothing leaves your machine except the SimpleFIN request itself.

<div align="center"><img src="docs/screenshot.png" width="760" alt="Phinny dashboard" /></div>

## Architecture

Native SwiftUI + Swift Charts. No Electron, no web view. The whole app is a thin pipeline:

```
SimpleFIN  ──claim──►  access URL (Keychain)
    │
    └──fetch──►  SimpleFINClient  ──►  AppDatabase (SQLite)  ──►  Analytics  ──►  SwiftUI charts
```

| Layer | File | Responsibility |
|---|---|---|
| Entry | `Sources/PhinnyApp.swift` | App + window, kicks off `bootstrap()` |
| State | `Sources/AppState.swift` | Single `@MainActor` source of truth; sync policy |
| Network | `Sources/SimpleFINClient.swift` | Claim token, fetch accounts (the only rate-limited call) |
| Import | `Sources/StatementImporter.swift` | Pure parser for Apple Card CSV/OFX/QFX/QBO exports |
| Storage | `Sources/Database.swift` | GRDB/SQLite schema, reads & writes |
| Secrets | `Sources/Keychain.swift` | SimpleFIN access URL in the macOS Keychain |
| Config | `Sources/Config.swift` | `~/.phinny/config.yaml` (non-sensitive settings) |
| Charts data | `Sources/Analytics.swift` | Pure aggregation functions (easy to test) |
| Demo data | `Sources/DemoData.swift` | Generates the bundled sample database |
| UI | `Sources/Views/*` | Connect sheet, dashboard, charts, transactions |

### Demo mode vs. connected mode

Phinny has two modes:

- **Demo** (default, no account connected): the app opens the bundled `phinny-demo.sqlite` sample data. **No network calls at all.** A banner offers to connect a real account.
- **Connected**: once a SimpleFIN access URL is in the Keychain, the app reads/writes the real `~/.phinny/phinny.sqlite` and syncs.

The bundled demo database is generated from `Sources/DemoData.swift` via the real DB code, so it always matches the schema. Regenerate it with `./scripts/generate-demo-db.sh` (commit the resulting `Resources/phinny-demo.sqlite`).

### Apple Card import

Apple Card is the one account SimpleFIN can't sync: Apple deliberately blocks third-party aggregators (Plaid, MX, and therefore SimpleFIN) from Apple Card data. The only reliable feed is the statement file you export yourself.

On your **iPhone or iPad** (there is no Mac equivalent), open Wallet → Apple Card → Card Balance → a **closed monthly statement** → **Export Transactions**, choose CSV / OFX / QFX / QBO, and send the file to your Mac (AirDrop, Files, or iCloud). In Phinny, use **Import Apple Card** (in the dashboard header, or the ⋯ menu when connected) and pick the file.

- **Standalone or supplemental.** If you only have an Apple Card, import works with no SimpleFIN account connected at all (an "import-only" mode). Phinny opens the real `~/.phinny/phinny.sqlite` and hides "Sync Now" since there's nothing to sync.
- **Closed statements only.** Apple only exports a statement once its cycle closes, so the current/unbilled cycle won't appear yet. This is an inherently monthly, manual import.
- **Idempotent.** Re-importing an overlapping month doesn't create duplicates: OFX/QFX rows carry a stable id (`FITID`), and CSV rows (which have none) are keyed by a deterministic content hash. Apple Card lands as a single synthetic account, and `StatementImporter` normalizes amounts to Phinny's sign convention (a purchase is spending). Imported transactions categorize, link to mortgages, and auto-detect as transfers exactly like synced ones.

### Mortgages

Mortgages are stored in their own tables (migration v2) that **sync never touches**, so manual entries survive. You enter only the facts (loan amount, down payment, interest rate, term, start date) and `MortgageEngine` computes the month-by-month amortization. It supports:

- **Rate changes over time** (ARM resets / refinances): the engine re-amortizes the remaining balance over the remaining term from each effective date.
- **Home value over time**: valuations are carried forward (step function) so equity is computed correctly at any date.
- **Extra principal payments**: manual transactions that shorten the loan, stored separately from synced data.
- **Linking real payments + escrow**: mark a synced expense as the mortgage payment and Phinny auto-links matching historical transactions (or detects the recurring payment for you). The amortization always uses the computed principal & interest as the source of truth, so a payment that bundles escrow never corrupts your balance; instead Phinny back-calculates escrow (taxes & insurance) as the difference between the real payment and the scheduled P&I.
- **Interactive home-value chart**: double-click to add a valuation where you click, drag points to adjust (everything recomputes live), or click a point to edit its exact value/date.
- **Zillow lookups**: paste a property's Zillow page URL (the `homedetails/.../<zpid>_zpid/` link) in the mortgage editor, then hit "Update from Zillow" to pull the current Zestimate as a `zillow`-sourced valuation. The lookup loads the page in an offscreen WebKit view (a real browser engine), so it works where a plain HTTP request gets bot-blocked; an address-only fallback search exists but is unreliable, so the direct link is preferred. Manual trigger only. (Dev tip: `PHINNY_ZILLOW_TEST="<url-or-address>"` on a Debug build prints the scraped value and exits.)

`MortgageEngine` is pure (no I/O), so all the math is easy to read and reason about.

### Where data lives

| What | Where | Why |
|---|---|---|
| Account + transaction data | `~/.phinny/phinny.sqlite` | Local SQLite via GRDB |
| Bundled demo data (when not connected) | app bundle, copied to `~/.phinny/phinny-demo.sqlite` | Sample data, no network |
| Settings (sync interval, history window) | `~/.phinny/config.yaml` | Human-editable YAML, non-sensitive |
| SimpleFIN access URL (bank credentials) | macOS Keychain | Encrypted, never written to disk in plaintext |

The app is **not sandboxed** on purpose, so it can use the shared `~/.phinny` directory. It is signed with the hardened runtime and notarized for distribution (see the entitlements files for the full rationale).

## The sync budget (important)

SimpleFIN allows roughly **24 requests per day**. Phinny is careful with them:

- The **claim** step runs once per token. The resulting access URL is reused forever, so connecting again costs nothing.
- Only `GET /accounts` counts against the budget.
- On launch, Phinny auto-syncs **only if** there's no data yet or the last sync is older than `min_interval_hours` (default 6). Relaunching repeatedly will not burn requests.
- "Sync Now" (⌘R) is always available for a manual refresh.

While developing, just use **demo mode** (the default), which reads bundled sample data and never touches your real account's budget.

## Development

Requirements: macOS 14+, Xcode 26+, and [XcodeGen](https://github.com/yonsson/XcodeGen) (`brew install xcodegen`).

```bash
# Build + run for development (demo data unless a token is set, see below)
./scripts/run.sh

# Build a dev-signed .app without launching
./scripts/build-app.sh && open dist/Phinny.app

# Regenerate the procedurally-drawn app icon
swift scripts/generate-icon.swift

# Regenerate the bundled demo database
./scripts/generate-demo-db.sh

# Open in Xcode to iterate
xcodegen generate && open Phinny.xcodeproj
```

`Phinny.xcodeproj` and `Resources/Info.plist` are generated and git-ignored - edit `project.yml`, not the generated files.

### Testing with real data

To point a dev build at your real account without pasting a token through the UI each time, copy `.env.example` to `.env` and set your token:

```bash
cp .env.example .env
echo 'SIMPLEFIN_TOKEN=your-setup-token' >> .env
./scripts/run.sh    # Debug build auto-connects on first launch (one real sync)
```

The token is single-use: after the first connect the access URL is stored in your Keychain and `.env` is ignored. `run.sh` launches the binary directly (not via `open`) so the variable reaches the app. Be mindful of the ~24 syncs/day budget.

See [`AGENTS.md`](AGENTS.md) for conventions and a map for coding agents.

## Release & signing

Local signed/notarized build (needs `.env.signing.local`, see `.env.signing.local.example`):

```bash
cp .env.signing.local.example .env.signing.local   # fill in Apple credentials
./scripts/build-signed-local.sh                     # → dist/Phinny.dmg + Phinny.zip
```

CI builds, signs, notarizes, and attaches a DMG to a GitHub Release on any `v*` tag
(`.github/workflows/release.yml`). Required repo secrets:

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

A self-contained single-page site lives in [`docs/`](docs/index.html) - plain HTML/CSS, no build step. Host it anywhere static, or proxy it at `dallinromney.com/phinny`.

## License

© 2026 Dallin Romney.
