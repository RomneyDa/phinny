import Foundation
import SwiftUI

/// The single source of truth for the UI. In the wrapper architecture this is a
/// thin client over the bundled `phinny` Go engine (see `PhinnyDaemon`): it
/// launches `phinny serve --stdio`, loads a full snapshot after every change,
/// and publishes what the views render. All persistence, syncing, importing,
/// categorization, transfer/mortgage logic, and Zillow lookups run in the engine.
///
/// Reads are local (over the last snapshot); writes go to the engine and then
/// reload. Writes are serialized through `writeChain` so ordering is preserved
/// (e.g. create-category-then-tag-with-it).
@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case loading
        case demo
        case ready
    }

    /// Suggested download for the Zillow peer dependency.
    static let chromeInstallURL = URL(string: "https://www.google.com/chrome/")!

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
    @Published private(set) var transferExclusions: Set<String> = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var errorMessage: String?
    @Published var importMessage: String?
    @Published var showingConnectSheet = false
    /// Whether a Chromium browser (the Zillow peer dependency) is installed.
    @Published private(set) var chromeAvailable = true

    private var daemon: PhinnyDaemon?
    private var mode = "loading"
    private var connectedFlag = false
    private var minIntervalHours = 6

    // Derived caches (rebuilt once per snapshot in `apply`).
    private(set) var categoriesById: [String: SpendCategory] = [:]
    private var linksByTransaction: [String: [ExpenseCategory]] = [:]
    private var mortgagesById: [String: Mortgage] = [:]
    private var mortgageIdByPaymentTxn: [String: String] = [:]
    private var mortgageSummaries: [String: MortgageEngine.Summary] = [:]
    private var mortgageSchedules: [String: [MortgageEngine.Point]] = [:]

    var isDemo: Bool { phase == .demo }
    var isImportOnly: Bool { mode == "import-only" }
    var isConnected: Bool { connectedFlag }

    // MARK: - Lifecycle

    func bootstrap() async {
        let env = ProcessInfo.processInfo.environment
        let forceDemo = env["PHINNY_FORCE_DEMO"] == "1"
        do {
            daemon = try PhinnyDaemon(forceDemo: forceDemo)
        } catch {
            errorMessage = error.localizedDescription
            phase = .demo
            return
        }

        await load()

        // Dev convenience: auto-connect from a SIMPLEFIN_TOKEN in .env (Debug).
        #if DEBUG
        if !isConnected,
           let token = env["SIMPLEFIN_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            await connect(setupToken: token)
            return
        }
        #endif

        // Stale-only auto-sync (protects the provider's ~24 requests/day budget).
        if isConnected && shouldAutoSync {
            await sync()
        }
    }

    func shutdown() { daemon?.shutdown() }

    private var shouldAutoSync: Bool {
        if transactions.isEmpty { return true }
        guard let last = lastSync else { return true }
        return Date().timeIntervalSince(last) > TimeInterval(minIntervalHours * 3600)
    }

    // MARK: - Snapshot load

    /// Pull the full snapshot from the engine and republish.
    private func load() async {
        guard let daemon else { return }
        do {
            let state = try await daemon.decode(DaemonState.self, "state")
            apply(state)
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
        }
    }

    private func apply(_ s: DaemonState) {
        mode = s.mode
        connectedFlag = s.connected
        minIntervalHours = max(1, s.config.sync.minIntervalHours)
        chromeAvailable = s.chromeAvailable
        primaryCurrency = s.primaryCurrency.isEmpty ? "USD" : s.primaryCurrency
        lastSync = s.lastSync.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        accounts = s.accounts
        transactions = s.transactions
        categories = s.categories
        expenseCategories = s.expenseCategories
        transferExclusions = Set(s.transferExclusions.map { $0.transactionId })
        mortgages = s.mortgages
        rateChanges = s.rateChanges
        valuations = s.valuations
        manualTxns = s.manualTxns
        paymentLinks = s.paymentLinks

        summary = s.dashboard.summary
        monthlyFlows = s.dashboard.monthlyFlows
        topSpending = s.dashboard.topSpending
        mortgageSummaries = s.mortgageSummaries
        mortgageSchedules = s.mortgageSchedules

        rebuildDerived()
        phase = (mode == "demo") ? .demo : .ready
    }

    private func rebuildDerived() {
        categoriesById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        linksByTransaction = Dictionary(grouping: expenseCategories, by: { $0.transactionId })
        mortgagesById = Dictionary(mortgages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        mortgageIdByPaymentTxn = Dictionary(
            paymentLinks.map { ($0.transactionId, $0.mortgageId) }, uniquingKeysWith: { a, _ in a })

        hiddenAccountIds = Set(accounts.filter { $0.hidden }.map { $0.id })
        let hidden = hiddenAccountIds
        visibleAccounts = hidden.isEmpty ? accounts : accounts.filter { !hidden.contains($0.id) }
        visibleTransactions = hidden.isEmpty
            ? transactions
            : transactions.filter { !hidden.contains($0.accountId) }
    }

    // MARK: - Write pipeline (ordered, fire-and-forget)

    private var writeChain = Task<Void, Never> {}

    private func enqueue(_ op: @escaping () async -> Void) {
        let prev = writeChain
        writeChain = Task { @MainActor in
            _ = await prev.value
            await op()
        }
    }

    private func mutate(_ method: String, _ params: [String: Any] = [:]) {
        // Serialize to Sendable Data on the main actor before crossing into the
        // write pipeline (a [String: Any] is not Sendable).
        let data = params.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: params)
        runWrite(method, data)
    }

    private func mutateEncodable<P: Encodable>(_ method: String, _ params: P) {
        let data = try? JSONEncoder().encode(params)
        runWrite(method, data)
    }

    private func runWrite(_ method: String, _ paramsData: Data?) {
        enqueue { [weak self] in
            guard let self, let d = self.daemon else { return }
            do {
                _ = try await d.send(method, raw: paramsData)
                await self.load()
            } catch {
                self.errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
            }
        }
    }

    // MARK: - Connect / disconnect / sync / import

    func connect(setupToken: String) async {
        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await daemon?.send("connect", ["token": setupToken])
            showingConnectSheet = false
            await load()
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
        }
    }

    func disconnect() async {
        errorMessage = nil
        do {
            _ = try await daemon?.send("disconnect")
            await load()
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
        }
    }

    func sync(force: Bool = false) async {
        guard isConnected else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            _ = try await daemon?.send("sync", ["force": force])
            await load()
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
        }
    }

    func importStatement(from url: URL) async {
        errorMessage = nil
        importMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let resp = try await daemon?.send("import", [
                "data_base64": data.base64EncodedString(),
                "filename": url.lastPathComponent,
            ])
            if let resp, let r = try? JSONDecoder().decode(ImportReply.self, from: resp) {
                importMessage = r.message
            }
            await load()
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
        }
    }

    private struct ImportReply: Decodable { let imported: Int; let message: String }

    func setAccountHidden(_ accountId: String, hidden: Bool) {
        mutate("accounts.hide", ["id": accountId, "hidden": hidden])
    }

    // MARK: - Mortgage reads

    func rateChanges(for id: String) -> [MortgageRateChange] {
        rateChanges.filter { $0.mortgageId == id }
    }

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

    /// Cached engine-computed summary (as of now). `asOf` is accepted for source
    /// compatibility; the engine computes as of the current time.
    func summary(for m: Mortgage, asOf now: Date = Date()) -> MortgageEngine.Summary {
        mortgageSummaries[m.id] ?? MortgageEngine.Summary()
    }
    func schedule(for m: Mortgage) -> [MortgageEngine.Point] {
        mortgageSchedules[m.id] ?? []
    }

    func mortgage(forPayment txn: Transaction) -> Mortgage? {
        guard let id = mortgageIdByPaymentTxn[txn.id] else { return nil }
        return mortgagesById[id]
    }

    func similarTransactions(to txn: Transaction) -> [Transaction] {
        let sig = MortgageDetection.normalize(txn.payee ?? txn.descriptionText)
        guard !sig.isEmpty else { return [txn] }
        return transactions.filter {
            $0.accountId == txn.accountId
                && MortgageDetection.normalize($0.payee ?? $0.descriptionText) == sig
        }
    }

    func makeDraftMortgage() -> Mortgage {
        Mortgage(id: newId(), name: "", principal: 400000, downKind: "percent", downValue: 20,
                 annualRate: 6.5, termMonths: 360, startDate: epoch(),
                 paymentPayee: nil, paymentAmount: nil, createdAt: epoch())
    }

    // MARK: - Mortgage writes

    @discardableResult
    func upsertMortgage(_ m: Mortgage) -> Mortgage {
        var saved = m
        if saved.id.isEmpty { saved.id = newId() }
        mutateEncodable("mortgages.upsert", saved)
        return saved
    }
    func deleteMortgage(_ id: String) { mutate("mortgages.delete", ["id": id]) }

    func addRateChange(mortgageId: String, date: Date, annualRate: Double) {
        mutate("mortgages.addRate", ["mortgage": mortgageId, "date": epoch(date), "annual_rate": annualRate])
    }
    func addValuation(mortgageId: String, date: Date, value: Double, source: String? = nil) {
        var p: [String: Any] = ["mortgage": mortgageId, "date": epoch(date), "value": value]
        if let source { p["source"] = source }
        mutate("mortgages.addValuation", p)
    }
    func addManualTxn(mortgageId: String, date: Date, amount: Double, note: String?) {
        var p: [String: Any] = ["mortgage": mortgageId, "date": epoch(date), "amount": amount]
        if let note { p["note"] = note }
        mutate("mortgages.addManual", p)
    }
    func deleteMortgageChild(table: String, id: String) {
        mutate("mortgages.deleteChild", ["table": table, "id": id])
    }

    /// Persist a dragged/edited valuation (preserving its id) and clear the live override.
    func commitValuation(_ v: HomeValuation) {
        liveValuation = nil
        mutateEncodable("mortgages.saveValuation", v)
    }
    func updateValuation(_ v: HomeValuation) {
        mutateEncodable("mortgages.saveValuation", v)
    }

    @discardableResult
    func markAsPayment(_ txn: Transaction, mortgageId: String) -> Int {
        mutate("mortgages.markPayment", ["transaction": txn.id, "mortgage": mortgageId])
        return 0
    }
    func unlinkPayment(_ txn: Transaction) {
        mutate("mortgages.unlinkPayment", ["transaction": txn.id])
    }
    func applyDetectedPayment(_ suggestion: MortgageDetection.Suggestion, mortgageId: String) {
        mutate("mortgages.applyPayment", [
            "mortgage": mortgageId, "payee": suggestion.payee, "amount": suggestion.amount,
        ])
    }

    func detectPayment(for m: Mortgage) async -> MortgageDetection.Suggestion? {
        guard let daemon else { return nil }
        do {
            let data = try await daemon.send("mortgages.detectPayment", ["mortgage": m.id])
            if (try? JSONSerialization.jsonObject(with: data)) is NSNull { return nil }
            return try? JSONDecoder().decode(MortgageDetection.Suggestion.self, from: data)
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Zillow

    @Published private(set) var zillowFetching: Set<String> = []
    @Published var zillowError: String?

    func isFetchingZillow(_ id: String) -> Bool { zillowFetching.contains(id) }

    func fetchZillowValuation(for m: Mortgage) async {
        zillowError = nil
        zillowFetching.insert(m.id)
        defer { zillowFetching.remove(m.id) }
        do {
            _ = try await daemon?.send("zillow.fetch", ["mortgage": m.id])
            await load()
        } catch let e as DaemonError {
            if e.code == "chrome_not_installed" { chromeAvailable = false }
            zillowError = e.message
        } catch {
            zillowError = error.localizedDescription
        }
    }

    // MARK: - Category reads

    func links(forTransaction id: String) -> [ExpenseCategory] {
        linksByTransaction[id] ?? []
    }
    private func applicableLinks(for txn: Transaction) -> [ExpenseCategory] {
        links(forTransaction: txn.id).filter { $0.applies(toPosted: txn.posted) }
    }
    func effectiveCategory(for txn: Transaction) -> SpendCategory? {
        let chosen = applicableLinks(for: txn).max { a, b in
            if a.isAuto != b.isAuto { return a.isAuto && !b.isAuto }
            return a.createdAt < b.createdAt
        }
        return chosen.flatMap { categoriesById[$0.categoryId] }
    }
    func appliedCategories(for txn: Transaction) -> [SpendCategory] {
        applicableLinks(for: txn).compactMap { categoriesById[$0.categoryId] }
    }
    func categoryLabel(for txn: Transaction) -> String {
        effectiveCategory(for: txn)?.name ?? txn.groupLabel
    }
    func usageCount(categoryId: String) -> Int {
        Set(expenseCategories.filter { $0.categoryId == categoryId }.map { $0.transactionId }).count
    }

    // MARK: - Category writes

    @discardableResult
    func addCategory(name: String, colorHex: String? = nil) -> SpendCategory {
        let c = SpendCategory(
            id: newId(), name: name,
            colorHex: colorHex ?? Theme.nextCategoryColor(existing: categories.count),
            createdAt: epoch(), isTransfer: false)
        // Optimistic local insert so the returned id is usable immediately.
        categories.append(c)
        categoriesById[c.id] = c
        mutateEncodable("categories.upsert", c)
        return c
    }
    func updateCategory(_ c: SpendCategory) { mutateEncodable("categories.upsert", c) }
    func deleteCategory(_ id: String) {
        guard id != SpendCategory.transferId else { return }
        mutate("categories.delete", ["id": id])
    }

    func setCategory(_ txn: Transaction, categoryId: String?) {
        mutate("categorize.set", ["transaction": txn.id, "category": categoryId ?? ""])
    }
    func addManualLink(transactionId: String, categoryId: String, start: Date? = nil, end: Date? = nil) {
        var p: [String: Any] = ["transaction": transactionId, "category": categoryId]
        if let start { p["start"] = epoch(start) }
        if let end { p["end"] = epoch(end) }
        mutate("categorize.manual", p)
    }
    func autoAssign(transactionId: String, categoryId: String, start: Date? = nil, end: Date? = nil) {
        var p: [String: Any] = ["transaction": transactionId, "category": categoryId]
        if let start { p["start"] = epoch(start) }
        if let end { p["end"] = epoch(end) }
        mutate("categorize.auto", p)
    }
    func removeLink(_ id: String) { mutate("categorize.removeLink", ["id": id]) }
    func clearCategories(transactionId: String) {
        mutate("categorize.clear", ["transaction": transactionId])
    }
    func toggleCategory(_ txn: Transaction, categoryId: String) {
        mutate("categorize.toggle", ["transaction": txn.id, "category": categoryId])
    }

    // MARK: - Transfers

    var transferCategory: SpendCategory? { categoriesById[SpendCategory.transferId] }

    func isTransfer(_ txn: Transaction) -> Bool {
        effectiveCategory(for: txn)?.isTransfer == true
    }
    func markAsTransfer(_ txn: Transaction) { mutate("transfers.mark", ["transaction": txn.id]) }
    func markNotTransfer(_ txn: Transaction) { mutate("transfers.unmark", ["transaction": txn.id]) }

    @discardableResult
    func autoDetectTransfers() async -> Int {
        guard let daemon else { return 0 }
        do {
            let data = try await daemon.send("transfers.detect")
            struct Reply: Decodable { let added: Int }
            let r = try JSONDecoder().decode(Reply.self, from: data)
            await load()
            return r.added
        } catch {
            errorMessage = (error as? DaemonError)?.message ?? error.localizedDescription
            return 0
        }
    }

    // MARK: - Derived data for the dashboard

    private(set) var hiddenAccountIds: Set<String> = []
    private(set) var visibleAccounts: [Account] = []
    private(set) var visibleTransactions: [Transaction] = []
    private(set) var summary = Analytics.Summary()
    private(set) var monthlyFlows: [Analytics.MonthlyFlow] = []
    private(set) var topSpending: [Analytics.CategorySpend] = []
    private(set) var primaryCurrency: String = "USD"

    // MARK: - Helpers

    private func epoch(_ d: Date = Date()) -> Int { Int(d.timeIntervalSince1970) }
    private func newId() -> String { UUID().uuidString }
}

/// The one-shot snapshot returned by the engine's `state` method.
private struct DaemonState: Decodable {
    var mode: String
    var connected: Bool
    var importOnly: Bool
    var writable: Bool
    var lastSync: Int?
    var chromeAvailable: Bool
    var primaryCurrency: String
    var config: DaemonConfig
    var accounts: [Account]
    var transactions: [Transaction]
    var categories: [SpendCategory]
    var expenseCategories: [ExpenseCategory]
    var transferExclusions: [TransferExclusion]
    var mortgages: [Mortgage]
    var rateChanges: [MortgageRateChange]
    var valuations: [HomeValuation]
    var manualTxns: [MortgageManualTxn]
    var paymentLinks: [MortgagePaymentLink]
    var dashboard: Analytics.DashboardData
    var mortgageSummaries: [String: MortgageEngine.Summary]
    var mortgageSchedules: [String: [MortgageEngine.Point]]

    enum CodingKeys: String, CodingKey {
        case mode, connected, writable, dashboard, accounts, transactions, categories, mortgages, valuations
        case importOnly = "import_only"
        case lastSync = "last_sync"
        case chromeAvailable = "chrome_available"
        case primaryCurrency = "primary_currency"
        case config
        case expenseCategories = "expense_categories"
        case transferExclusions = "transfer_exclusions"
        case rateChanges = "rate_changes"
        case manualTxns = "manual_txns"
        case paymentLinks = "payment_links"
        case mortgageSummaries = "mortgage_summaries"
        case mortgageSchedules = "mortgage_schedules"
    }
}

private struct DaemonConfig: Decodable {
    var sync: SyncConfig
    struct SyncConfig: Decodable {
        var minIntervalHours: Int
        var historyDays: Int
        enum CodingKeys: String, CodingKey {
            case minIntervalHours = "min_interval_hours"
            case historyDays = "history_days"
        }
    }
}
