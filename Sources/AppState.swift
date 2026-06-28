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
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var errorMessage: String?
    @Published var showingConnectSheet = false

    private var config = Config()
    private var database: AppDatabase?

    var isDemo: Bool { phase == .demo }
    private var accessURL: String? { Keychain.accessURL() }

    // MARK: - Lifecycle

    func bootstrap() async {
        config = ConfigStore.load()
        // Materialize config.yaml on first run so settings are discoverable/editable.
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            try? ConfigStore.save(config)
        }

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

        if Keychain.hasAccessURL {
            await enterConnectedMode(autoSync: true)
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

    /// Forget the SimpleFIN connection and fall back to demo data.
    func disconnect() {
        Keychain.deleteAccessURL()
        errorMessage = nil
        enterDemoMode()
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
    }

    // MARK: - Mortgages

    func rateChanges(for id: String) -> [MortgageRateChange] {
        rateChanges.filter { $0.mortgageId == id }
    }
    func valuations(for id: String) -> [HomeValuation] {
        valuations.filter { $0.mortgageId == id }
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
    func addValuation(mortgageId: String, date: Date, value: Double) {
        try? database?.saveValuation(HomeValuation(
            id: newId(), mortgageId: mortgageId, date: epoch(date), value: value))
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

    /// Mark a synced transaction as this mortgage's payment, then auto-link all
    /// matching historical transactions.
    func markAsPayment(_ txn: Transaction, mortgageId: String) {
        guard var m = mortgages.first(where: { $0.id == mortgageId }) else { return }
        m.paymentPayee = txn.payee ?? txn.descriptionText
        m.paymentAmount = txn.amount
        try? database?.saveMortgage(m)
        relinkPayments(for: m)
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

    // MARK: - Derived data for the dashboard

    var summary: Analytics.Summary {
        Analytics.summary(accounts: accounts, transactions: transactions)
    }
    var monthlyFlows: [Analytics.MonthlyFlow] {
        Analytics.monthlyFlows(transactions)
    }
    var topSpending: [Analytics.CategorySpend] {
        Analytics.topSpending(transactions)
    }
    var primaryCurrency: String { accounts.first?.currency ?? "USD" }
}
