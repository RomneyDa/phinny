import Foundation
import SwiftUI

/// The single source of truth for the UI. Owns the config + database, runs
/// syncs, and publishes the data the views render.
///
/// Two modes:
///   • demo      - no account connected. Reads the bundled `phinny-demo.sqlite`
///                 sample data. No network calls at all.
///   • connected - a SimpleFIN access URL is in the Keychain. Reads/writes the
///                 real `~/.phinny/phinny.sqlite` and syncs.
///
/// Sync policy (protects the provider's ~24 requests/day budget): on launch we
/// auto-sync only if there's no data yet or the last sync is older than
/// `config.sync.minIntervalHours`. "Sync Now" is always available for a manual
/// refresh.
@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case loading
        case demo       // showing bundled sample data
        case ready      // connected to a real account
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var transactions: [Transaction] = []
    @Published private(set) var mortgages: [Mortgage] = []
    @Published private(set) var rateChanges: [MortgageRateChange] = []
    @Published private(set) var valuations: [HomeValuation] = []
    @Published private(set) var manualTxns: [MortgageManualTxn] = []
    @Published private(set) var paymentLinks: [MortgagePaymentLink] = []
    @Published private(set) var categories: [SpendCategory] = []
    @Published private(set) var expenseCategories: [ExpenseCategory] = []
    /// Transaction ids the user explicitly marked "not a transfer".
    @Published private(set) var transferExclusions: Set<String> = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var errorMessage: String?
    /// Transient result of the last statement import (e.g. "Imported 47...").
    @Published var importMessage: String?
    @Published var showingConnectSheet = false

    private var config = Config()
    private var database: AppDatabase?

    var isDemo: Bool { phase == .demo }
    /// Ready with imported data but no SimpleFIN account connected. In this mode
    /// there is nothing to sync, so the dashboard hides "Sync Now".
    var isImportOnly: Bool { phase == .ready && accessURL == nil }
    private var accessURL: String? { Keychain.accessURL() }

    // MARK: - Lifecycle

    func bootstrap() async {
        config = ConfigStore.load()
        // Materialize config.yaml on first run so settings are discoverable/editable.
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            try? ConfigStore.save(config)
        }

        // Dev tool: probe a Zillow address from the CLI and exit.
        #if DEBUG
        if let addr = ProcessInfo.processInfo.environment["PHINNY_ZILLOW_TEST"] {
            let scraper = ZillowScraper()
            do {
                let v = try await scraper.fetchZestimate(address: addr)
                print("ZILLOW_RESULT|\(addr)|\(Int(v))|\(scraper.lastURL)|\(scraper.lastTitle)")
            } catch {
                print("ZILLOW_ERROR|\(addr)|\(error.localizedDescription)|\(scraper.lastURL)|\(scraper.lastTitle)")
            }
            fflush(stdout)
            exit(0)
        }
        #endif

        // Dev convenience: force demo mode regardless of any connected account
        // (for testing/screenshots). Does not touch the real database or Keychain.
        #if DEBUG
        if ProcessInfo.processInfo.environment["PHINNY_FORCE_DEMO"] == "1" {
            enterDemoMode()
            return
        }
        #endif

        // Dev convenience: auto-connect from a SIMPLEFIN_TOKEN in .env (Debug only).
        // Run via ./scripts/run.sh so the variable reaches the app.
        #if DEBUG
        if !Keychain.hasAccessURL,
           let token = ProcessInfo.processInfo.environment["SIMPLEFIN_TOKEN"]?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            await connect(setupToken: token)
            return
        }
        #endif

        // Connected to SimpleFIN -> open + auto-sync the real DB. If there's no
        // token but a real DB already exists (e.g. Apple Card statements were
        // imported), reopen it in import-only mode (no sync). Otherwise demo.
        if Keychain.hasAccessURL {
            await enterConnectedMode(autoSync: true)
        } else if FileManager.default.fileExists(atPath: Paths.databaseFile.path),
                  let db = try? AppDatabase(path: Paths.databaseFile),
                  db.accountExists(id: StatementImporter.accountId) {
            await enterConnectedMode(autoSync: false)
        } else {
            enterDemoMode()
        }
    }

    // MARK: - Modes

    private func enterConnectedMode(autoSync: Bool) async {
        do {
            let db = try AppDatabase(path: Paths.databaseFile)
            database = db
            lastSync = db.lastSync()
            loadFromDatabase()
            phase = .ready
            if autoSync && shouldAutoSync { await sync() }
        } catch {
            errorMessage = "Could not open the database: \(error.localizedDescription)"
            enterDemoMode()
        }
    }

    private func enterDemoMode() {
        lastSync = nil
        do {
            let url = try prepareDemoDatabase()
            database = try AppDatabase(path: url)
            loadFromDatabase()
        } catch {
            accounts = []
            transactions = []
            database = nil
        }
        phase = .demo
    }

    /// Copy the bundled demo database to a writable location (overwriting any
    /// previous copy so it stays fresh) and return its URL.
    private func prepareDemoDatabase() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "phinny-demo", withExtension: "sqlite") else {
            throw NSError(domain: "Phinny", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled demo database is missing."])
        }
        try Paths.ensureConfigDir()
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: Paths.demoDatabaseFile.path + suffix))
        }
        try fm.copyItem(at: bundled, to: Paths.demoDatabaseFile)
        return Paths.demoDatabaseFile
    }

    private var shouldAutoSync: Bool {
        if transactions.isEmpty { return true }
        guard let last = lastSync else { return true }
        let interval = TimeInterval(config.sync.minIntervalHours * 3600)
        return Date().timeIntervalSince(last) > interval
    }

    // MARK: - Connect / disconnect

    /// Claim a setup token, persist the resulting access URL, then sync.
    func connect(setupToken: String) async {
        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }
        do {
            let url = try await SimpleFINClient.claim(setupToken: setupToken)
            guard Keychain.setAccessURL(url) else {
                errorMessage = "Could not save credentials to the Keychain."
                return
            }
            showingConnectSheet = false
            await enterConnectedMode(autoSync: false)
            await sync(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forget the SimpleFIN connection. If Apple Card statements were imported,
    /// keep that data (import-only mode); otherwise fall back to demo data.
    func disconnect() async {
        Keychain.deleteAccessURL()
        errorMessage = nil
        if let db = try? AppDatabase(path: Paths.databaseFile),
           db.accountExists(id: StatementImporter.accountId) {
            await enterConnectedMode(autoSync: false)
        } else {
            enterDemoMode()
        }
    }

    // MARK: - Statement import (Apple Card)

    /// Import an Apple Card statement file (CSV / OFX / QFX / QBO) exported from
    /// the iPhone Wallet app. Writes through the same upsert path as sync, so
    /// re-importing an overlapping month is idempotent. Switches out of demo mode
    /// into the real (import-only) database on first import.
    func importStatement(from url: URL) async {
        errorMessage = nil
        importMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try StatementImporter.parse(data: data, filename: url.lastPathComponent)

            // Make sure we write to the real DB, never the demo copy.
            if database == nil || isDemo {
                database = try AppDatabase(path: Paths.databaseFile)
                phase = .ready
            }
            try database?.replace(accounts: result.accounts, transactions: result.transactions)
            loadFromDatabase()
            autoDetectTransfers()
            let n = result.transactions.count
            importMessage = "Imported \(n) Apple Card transaction\(n == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sync

    func sync(force: Bool = false) async {
        guard let database, let accessURL, !isSyncing || force else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let since = Calendar.current.date(
                byAdding: .day, value: -config.sync.historyDays, to: Date()
            ) ?? Date(timeIntervalSince1970: 0)
            let result = try await SimpleFINClient.fetchAccounts(accessURL: accessURL, since: since)
            try database.replace(accounts: result.accounts, transactions: result.transactions)
            let now = Date()
            try database.recordSync(at: now)
            lastSync = now
            loadFromDatabase()
            autoDetectTransfers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadFromDatabase() {
        guard let database else { return }
        accounts = (try? database.accounts()) ?? []
        transactions = (try? database.transactions()) ?? []
        mortgages = (try? database.mortgages()) ?? []
        rateChanges = (try? database.rateChanges()) ?? []
        valuations = (try? database.valuations()) ?? []
        manualTxns = (try? database.manualTxns()) ?? []
        paymentLinks = (try? database.paymentLinks()) ?? []
        categories = (try? database.categories()) ?? []
        expenseCategories = (try? database.expenseCategories()) ?? []
        transferExclusions = Set((try? database.transferExclusions())?.map { $0.transactionId } ?? [])
    }

    // MARK: - Mortgages

    func rateChanges(for id: String) -> [MortgageRateChange] {
        rateChanges.filter { $0.mortgageId == id }
    }
    /// A valuation being dragged on the chart. Merged into `valuations(for:)`
    /// so the whole detail view updates live without writing to disk each frame.
    @Published var liveValuation: HomeValuation?

    func valuations(for id: String) -> [HomeValuation] {
        var vs = valuations.filter { $0.mortgageId == id }
        if let live = liveValuation, live.mortgageId == id {
            if let i = vs.firstIndex(where: { $0.id == live.id }) { vs[i] = live }
            else { vs.append(live) }
        }
        return vs.sorted { $0.date < $1.date }
    }

    func setLiveValuation(_ v: HomeValuation?) { liveValuation = v }

    /// Persist the dragged valuation and clear the live override.
    func commitValuation(_ v: HomeValuation) {
        liveValuation = nil
        try? database?.saveValuation(v)
        loadFromDatabase()
    }

    func updateValuation(_ v: HomeValuation) {
        try? database?.saveValuation(v)
        loadFromDatabase()
    }
    func manualTxns(for id: String) -> [MortgageManualTxn] {
        manualTxns.filter { $0.mortgageId == id }
    }
    func linkedTransactionIds(for id: String) -> Set<String> {
        Set(paymentLinks.filter { $0.mortgageId == id }.map { $0.transactionId })
    }
    func linkedTransactions(for id: String) -> [Transaction] {
        let ids = linkedTransactionIds(for: id)
        return transactions.filter { ids.contains($0.id) }
    }

    func summary(for m: Mortgage, asOf now: Date = Date()) -> MortgageEngine.Summary {
        MortgageEngine.summary(for: m, rateChanges: rateChanges(for: m.id),
                               extraPayments: manualTxns(for: m.id),
                               valuations: valuations(for: m.id), asOf: now)
    }
    func schedule(for m: Mortgage) -> [MortgageEngine.Point] {
        MortgageEngine.schedule(for: m, rateChanges: rateChanges(for: m.id),
                                extraPayments: manualTxns(for: m.id),
                                valuations: valuations(for: m.id))
    }

    private func epoch(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
    private func newId() -> String { UUID().uuidString }

    @discardableResult
    func upsertMortgage(_ m: Mortgage) -> Mortgage {
        try? database?.saveMortgage(m)
        loadFromDatabase()
        return m
    }
    func deleteMortgage(_ id: String) {
        try? database?.deleteMortgage(id: id)
        loadFromDatabase()
    }
    func addRateChange(mortgageId: String, date: Date, annualRate: Double) {
        try? database?.saveRateChange(MortgageRateChange(
            id: newId(), mortgageId: mortgageId, effectiveDate: epoch(date), annualRate: annualRate))
        loadFromDatabase()
    }
    func addValuation(mortgageId: String, date: Date, value: Double, source: String? = nil) {
        try? database?.saveValuation(HomeValuation(
            id: newId(), mortgageId: mortgageId, date: epoch(date), value: value, source: source))
        loadFromDatabase()
    }
    func addManualTxn(mortgageId: String, date: Date, amount: Double, note: String?) {
        try? database?.saveManualTxn(MortgageManualTxn(
            id: newId(), mortgageId: mortgageId, date: epoch(date), amount: amount, note: note))
        loadFromDatabase()
    }
    func deleteMortgageChild(table: String, id: String) {
        try? database?.deleteMortgageChild(table: table, id: id)
        loadFromDatabase()
    }

    /// Mark a synced transaction as this mortgage's payment, then auto-link every
    /// other expense on the same account with the same title. Returns the total
    /// number of linked transactions (so the UI can confirm the auto-detection).
    @discardableResult
    func markAsPayment(_ txn: Transaction, mortgageId: String) -> Int {
        guard var m = mortgages.first(where: { $0.id == mortgageId }) else { return 0 }
        m.paymentPayee = txn.payee ?? txn.descriptionText
        m.paymentAmount = txn.amount
        m.paymentAccountId = txn.accountId
        try? database?.saveMortgage(m)
        relinkPayments(for: m)
        return linkedTransactionIds(for: mortgageId).count
    }

    /// The mortgage a transaction is linked to as a payment, if any.
    func mortgage(forPayment txn: Transaction) -> Mortgage? {
        guard let link = paymentLinks.first(where: { $0.transactionId == txn.id }) else { return nil }
        return mortgages.first(where: { $0.id == link.mortgageId })
    }

    /// Unlink a single transaction from being a mortgage payment. The mortgage's
    /// payment signature is left intact, so other matches stay linked.
    func unlinkPayment(_ txn: Transaction) {
        try? database?.removePaymentLink(transactionId: txn.id)
        loadFromDatabase()
    }

    /// Transactions that share this one's account and title (normalized
    /// payee/description), including itself, newest first. This is the same
    /// account + title grouping mortgage linking uses, so it doubles as a preview
    /// of what "link to mortgage" would catch.
    func similarTransactions(to txn: Transaction) -> [Transaction] {
        let sig = MortgageDetection.normalize(txn.payee ?? txn.descriptionText)
        guard !sig.isEmpty else { return [txn] }
        return transactions.filter {
            $0.accountId == txn.accountId
                && MortgageDetection.normalize($0.payee ?? $0.descriptionText) == sig
        }
    }

    func applyDetectedPayment(_ suggestion: MortgageDetection.Suggestion, mortgageId: String) {
        guard var m = mortgages.first(where: { $0.id == mortgageId }) else { return }
        m.paymentPayee = suggestion.payee
        m.paymentAmount = suggestion.amount
        try? database?.saveMortgage(m)
        relinkPayments(for: m)
    }

    func detectPayment(for m: Mortgage) -> MortgageDetection.Suggestion? {
        let expected = summary(for: m).monthlyPayment
        return MortgageDetection.detect(in: transactions, expectedPayment: expected)
    }

    // MARK: - Zillow

    @Published private(set) var zillowFetching: Set<String> = []
    @Published var zillowError: String?

    func isFetchingZillow(_ id: String) -> Bool { zillowFetching.contains(id) }

    /// Manual trigger: look up the current Zestimate for the mortgage's address
    /// and add it as a "zillow"-sourced valuation dated today.
    func fetchZillowValuation(for m: Mortgage) async {
        // Prefer the exact Zillow property URL; fall back to the address.
        let link = m.zillowUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = m.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = !link.isEmpty ? link : address
        guard !target.isEmpty else {
            zillowError = "Add a Zillow property link (Edit) to enable lookups."
            return
        }
        zillowError = nil
        zillowFetching.insert(m.id)
        defer { zillowFetching.remove(m.id) }
        do {
            let value = try await ZillowScraper().fetchZestimate(address: target)
            upsertZillowValuation(mortgageId: m.id, value: value)
        } catch {
            zillowError = error.localizedDescription
        }
    }

    /// Store today's Zillow value, replacing an earlier Zillow reading from the
    /// same day rather than stacking duplicate points.
    private func upsertZillowValuation(mortgageId: String, value: Double) {
        let today = Date()
        let existing = valuations.first {
            $0.mortgageId == mortgageId && $0.source == "zillow"
                && Calendar.current.isDate($0.asDate, inSameDayAs: today)
        }
        let id = existing?.id ?? newId()
        try? database?.saveValuation(HomeValuation(
            id: id, mortgageId: mortgageId, date: epoch(today), value: value, source: "zillow"))
        loadFromDatabase()
    }

    private func relinkPayments(for m: Mortgage) {
        try? database?.removePaymentLinks(mortgageId: m.id)
        let matched = MortgageDetection.matches(transactions, for: m)
        let links = matched.map { MortgagePaymentLink(transactionId: $0.id, mortgageId: m.id) }
        try? database?.addPaymentLinks(links)
        loadFromDatabase()
    }

    func makeDraftMortgage() -> Mortgage {
        Mortgage(id: newId(), name: "", principal: 400000, downKind: "percent", downValue: 20,
                 annualRate: 6.5, termMonths: 360, startDate: epoch(Date()),
                 paymentPayee: nil, paymentAmount: nil, createdAt: epoch(Date()))
    }

    // MARK: - Categories

    var categoriesById: [String: SpendCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    /// All links attached to a transaction (any window).
    func links(forTransaction id: String) -> [ExpenseCategory] {
        expenseCategories.filter { $0.transactionId == id }
    }

    /// The links that actually apply to a transaction (window contains its date).
    private func applicableLinks(for txn: Transaction) -> [ExpenseCategory] {
        links(forTransaction: txn.id).filter { $0.applies(toPosted: txn.posted) }
    }

    /// The single category shown for a transaction. Manual wins over auto, then
    /// the most recent link. Returns nil if nothing applies.
    func effectiveCategory(for txn: Transaction) -> SpendCategory? {
        let chosen = applicableLinks(for: txn).max { a, b in
            if a.isAuto != b.isAuto { return a.isAuto && !b.isAuto } // manual ranks higher
            return a.createdAt < b.createdAt                          // then newest
        }
        return chosen.flatMap { categoriesById[$0.categoryId] }
    }

    /// Every applicable category for a transaction (an expense may have several).
    func appliedCategories(for txn: Transaction) -> [SpendCategory] {
        applicableLinks(for: txn).compactMap { categoriesById[$0.categoryId] }
    }

    /// Label used by the spending chart: the effective category name, else the
    /// transaction's own group label.
    func categoryLabel(for txn: Transaction) -> String {
        effectiveCategory(for: txn)?.name ?? txn.groupLabel
    }

    /// How many transactions currently carry at least one link to a category.
    func usageCount(categoryId: String) -> Int {
        Set(expenseCategories.filter { $0.categoryId == categoryId }.map { $0.transactionId }).count
    }

    @discardableResult
    func addCategory(name: String, colorHex: String? = nil) -> SpendCategory {
        let c = SpendCategory(id: newId(), name: name,
                              colorHex: colorHex ?? Theme.nextCategoryColor(existing: categories.count),
                              createdAt: epoch(Date()))
        try? database?.saveCategory(c)
        loadFromDatabase()
        return c
    }
    func updateCategory(_ c: SpendCategory) {
        try? database?.saveCategory(c)
        loadFromDatabase()
    }
    func deleteCategory(_ id: String) {
        guard id != SpendCategory.transferId else { return }   // permanent
        try? database?.deleteCategory(id: id)   // cascades to its links
        loadFromDatabase()
    }

    /// Simple manual tagging: make `categoryId` the transaction's category,
    /// replacing any existing links. Pass nil to clear all categories. Applies to
    /// every similar transaction (same account + title) so categorizing a merchant
    /// once tags all of its transactions.
    func setCategory(_ txn: Transaction, categoryId: String?) {
        for t in similarTransactions(to: txn) {
            let links: [ExpenseCategory]
            if let categoryId {
                links = [ExpenseCategory(id: newId(), transactionId: t.id, categoryId: categoryId,
                                         startDate: nil, endDate: nil, isAuto: false,
                                         createdAt: epoch(Date()))]
            } else {
                links = []
            }
            try? database?.replaceExpenseCategories(transactionId: t.id, with: links)
        }
        loadFromDatabase()
    }

    /// Add a manual link, optionally windowed, without disturbing links to other
    /// categories. Any conflicting link (same category, overlapping window) is
    /// replaced; manual always wins.
    func addManualLink(transactionId: String, categoryId: String,
                       start: Date? = nil, end: Date? = nil) {
        let link = ExpenseCategory(
            id: newId(), transactionId: transactionId, categoryId: categoryId,
            startDate: start.map(epoch), endDate: end.map(epoch),
            isAuto: false, createdAt: epoch(Date()))
        for existing in conflicts(with: link) {
            try? database?.deleteExpenseCategory(id: existing.id)
        }
        try? database?.saveExpenseCategory(link)
        loadFromDatabase()
    }

    /// Auto-categorization entry point (for a future AI). Respects manual intent:
    /// if the transaction already has any manual link, it is left untouched.
    /// Otherwise the auto link replaces conflicting auto links.
    func autoAssign(transactionId: String, categoryId: String,
                    start: Date? = nil, end: Date? = nil) {
        if links(forTransaction: transactionId).contains(where: { !$0.isAuto }) { return }
        let link = ExpenseCategory(
            id: newId(), transactionId: transactionId, categoryId: categoryId,
            startDate: start.map(epoch), endDate: end.map(epoch),
            isAuto: true, createdAt: epoch(Date()))
        for existing in conflicts(with: link) where existing.isAuto {
            try? database?.deleteExpenseCategory(id: existing.id)
        }
        try? database?.saveExpenseCategory(link)
        loadFromDatabase()
    }

    func removeLink(_ id: String) {
        try? database?.deleteExpenseCategory(id: id)
        loadFromDatabase()
    }
    func clearCategories(transactionId: String) {
        let targets = transactions.first { $0.id == transactionId }
            .map { similarTransactions(to: $0).map(\.id) } ?? [transactionId]
        for id in targets {
            try? database?.replaceExpenseCategories(transactionId: id, with: [])
        }
        loadFromDatabase()
    }

    /// Toggle a manual link to `categoryId` on or off for this transaction,
    /// leaving links to other categories untouched. This is what the multi-select
    /// picker uses, so an expense can carry any combination of categories. Turning
    /// a category off removes every link to it (windowed or not); use the advanced
    /// sheet for per-window control.
    func toggleCategory(_ txn: Transaction, categoryId: String) {
        // Decide the direction from the clicked transaction, then apply it to the
        // whole group (same account + title) so a merchant is tagged in one click.
        let turningOn = !links(forTransaction: txn.id).contains { $0.categoryId == categoryId }
        for t in similarTransactions(to: txn) {
            let existing = links(forTransaction: t.id).filter { $0.categoryId == categoryId }
            if turningOn {
                if existing.isEmpty {
                    try? database?.saveExpenseCategory(ExpenseCategory(
                        id: newId(), transactionId: t.id, categoryId: categoryId,
                        startDate: nil, endDate: nil, isAuto: false, createdAt: epoch(Date())))
                }
            } else {
                for link in existing { try? database?.deleteExpenseCategory(id: link.id) }
            }
        }
        loadFromDatabase()
    }

    /// Existing links that conflict with `candidate`: same transaction + same
    /// category + overlapping window. (The only conflict the model recognizes.)
    private func conflicts(with candidate: ExpenseCategory) -> [ExpenseCategory] {
        links(forTransaction: candidate.transactionId).filter {
            $0.id != candidate.id
                && $0.categoryId == candidate.categoryId
                && ExpenseCategory.windowsOverlap($0, candidate)
        }
    }

    // MARK: - Transfers

    /// The permanent Transfer category (seeded by migration v6).
    var transferCategory: SpendCategory? { categoriesById[SpendCategory.transferId] }

    /// True if the transaction's effective category is flagged as a transfer, so
    /// it should not count toward income or spending.
    func isTransfer(_ txn: Transaction) -> Bool {
        effectiveCategory(for: txn)?.isTransfer == true
    }

    /// Manually mark a transaction as a transfer (a normal manual link to the
    /// Transfer category) and clear any "not a transfer" override.
    func markAsTransfer(_ txn: Transaction) {
        try? database?.deleteTransferExclusion(transactionId: txn.id)
        addManualLink(transactionId: txn.id, categoryId: SpendCategory.transferId)
    }

    /// Manually mark a transaction as NOT a transfer: drop any transfer links
    /// (manual or auto) and remember the decision so auto-detection never
    /// re-tags it.
    func markNotTransfer(_ txn: Transaction) {
        for link in links(forTransaction: txn.id) where link.categoryId == SpendCategory.transferId {
            try? database?.deleteExpenseCategory(id: link.id)
        }
        try? database?.saveTransferExclusion(transactionId: txn.id)
        loadFromDatabase()
    }

    /// Scan all transactions for transfer pairs and auto-link both legs to the
    /// Transfer category. Respects manual intent (skips transactions with any
    /// manual link) and "not a transfer" overrides. Returns the number of newly
    /// linked transactions. Pure detection lives in `TransferDetection`.
    @discardableResult
    func autoDetectTransfers() -> Int {
        guard let database, let cat = transferCategory else { return 0 }
        let detected = TransferDetection.detect(in: transactions)
        var added = 0
        for id in detected {
            if transferExclusions.contains(id) { continue }
            let existing = links(forTransaction: id)
            if existing.contains(where: { !$0.isAuto }) { continue }            // manual wins
            if existing.contains(where: { $0.categoryId == cat.id }) { continue } // already linked
            let link = ExpenseCategory(
                id: newId(), transactionId: id, categoryId: cat.id,
                startDate: nil, endDate: nil, isAuto: true, createdAt: epoch(Date()))
            try? database.saveExpenseCategory(link)
            added += 1
        }
        if added > 0 { loadFromDatabase() }
        return added
    }

    // MARK: - Derived data for the dashboard

    /// Transactions that count as real income/spending (transfers removed).
    private var spendingTransactions: [Transaction] {
        transactions.filter { !isTransfer($0) }
    }

    var summary: Analytics.Summary {
        Analytics.summary(accounts: accounts, transactions: spendingTransactions)
    }
    var monthlyFlows: [Analytics.MonthlyFlow] {
        Analytics.monthlyFlows(spendingTransactions)
    }
    var topSpending: [Analytics.CategorySpend] {
        Analytics.topSpending(spendingTransactions) { [self] in categoryLabel(for: $0) }
    }
    var primaryCurrency: String { accounts.first?.currency ?? "USD" }
}
