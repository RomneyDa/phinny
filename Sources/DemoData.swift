import Foundation

/// Synthesizes a realistic 12-month sample dataset and writes it to a SQLite
/// file using the real `AppDatabase` (so the demo file always matches the
/// current schema). Used to produce the bundled `phinny-demo.sqlite` that the
/// app shows when no SimpleFIN account is connected.
///
/// Regenerate with:  ./scripts/generate-demo-db.sh
enum DemoData {

    static let checkingId = "demo-checking"
    static let savingsId = "demo-savings"

    /// Build (accounts, transactions) for roughly the last 12 months, anchored
    /// to the current month so the dashboard looks current when shipped.
    static func make(now: Date = Date()) -> ([Account], [Transaction]) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        var txns: [Transaction] = []
        var rng = SplitMix(seed: 0x9E3779B9)

        func add(_ accountId: String, day: Int, monthOffset: Int, amount: Double,
                 desc: String, payee: String, category: String) {
            guard let base = cal.date(byAdding: .month, value: -monthOffset, to: monthStart),
                  let date = cal.date(byAdding: .day, value: day - 1, to: base),
                  date <= now else { return }
            let seq = txns.count
            txns.append(Transaction(
                id: "\(accountId)-\(seq)",
                providerId: "\(seq)",
                accountId: accountId,
                posted: Int(date.timeIntervalSince1970),
                amount: amount,
                descriptionText: desc,
                payee: payee,
                memo: nil,
                category: category,
                pending: false
            ))
        }

        // Merchant pools per category for variety.
        let groceries = ["Whole Foods", "Trader Joe's", "Safeway", "Costco"]
        let dining = ["Chipotle", "Blue Bottle Coffee", "Sushi Ya", "Local Thai", "Shake Shack", "Olive & Vine"]
        let transport = ["Shell", "Uber", "Chevron", "BART", "Lyft"]
        let shopping = ["Amazon", "Target", "Apple Store", "Best Buy", "REI"]

        for m in 0..<12 {
            // Calendar month (1...12) for this slot, so seasonal effects line up
            // with real months (holidays in December, vacation in summer, etc.).
            let calMonth: Int = {
                guard let base = cal.date(byAdding: .month, value: -m, to: monthStart) else { return 1 }
                return cal.component(.month, from: base)
            }()

            // Income: biweekly payroll. A promotion ~5 months ago bumped the
            // paycheck, so recent months sit visibly higher than older ones.
            let paycheck = m >= 5 ? 2600.0 : 3050.0
            add(checkingId, day: 1, monthOffset: m, amount: paycheck, desc: "Payroll - Acme Corp", payee: "Acme Corp", category: "Income")
            add(checkingId, day: 15, monthOffset: m, amount: paycheck, desc: "Payroll - Acme Corp", payee: "Acme Corp", category: "Income")

            // Freelance side income, roughly two months out of three.
            if rng.double(in: 0...1) < 0.65 {
                add(checkingId, day: 1 + rng.int(in: 0..<26), monthOffset: m,
                    amount: rng.double(in: 350...1450).rounded(to: 2),
                    desc: "Freelance project", payee: "Upwork", category: "Income")
            }

            // Lumpy seasonal income that makes the green bars jump.
            switch calMonth {
            case 12: add(checkingId, day: 20, monthOffset: m, amount: 7200, desc: "Year-end bonus", payee: "Acme Corp", category: "Income")
            case 7:  add(checkingId, day: 18, monthOffset: m, amount: 2400, desc: "Mid-year bonus", payee: "Acme Corp", category: "Income")
            case 4:  add(checkingId, day: 12, monthOffset: m, amount: 3120, desc: "Tax refund", payee: "IRS", category: "Income")
            default: break
            }

            // Mortgage payment (linked to the demo mortgage below).
            add(checkingId, day: 1, monthOffset: m, amount: -2300, desc: "Mortgage payment", payee: "Sunset Mortgage Co", category: "Housing")

            // Fixed monthly bills. Utilities swing with the season (summer AC,
            // winter heat) instead of sitting at a dead-flat number.
            let utilSwing = (calMonth == 7 || calMonth == 8 || calMonth == 12 || calMonth == 1) ? 1.55 : 1.0
            add(checkingId, day: 2, monthOffset: m, amount: -480, desc: "HOA dues", payee: "Maple Grove HOA", category: "Rent")
            add(checkingId, day: 10, monthOffset: m, amount: -(132.40 * utilSwing).rounded(to: 2), desc: "Electric & Gas", payee: "PG&E", category: "Utilities")
            add(checkingId, day: 10, monthOffset: m, amount: -79.99, desc: "Internet", payee: "Comcast", category: "Utilities")
            add(checkingId, day: 5, monthOffset: m, amount: -15.49, desc: "Netflix", payee: "Netflix", category: "Subscriptions")
            add(checkingId, day: 5, monthOffset: m, amount: -11.99, desc: "Spotify", payee: "Spotify", category: "Subscriptions")
            add(checkingId, day: 6, monthOffset: m, amount: -45, desc: "Gym membership", payee: "Iron Works Gym", category: "Health")

            // Savings: transfer + interest. The transfer grows after the raise.
            let saved = m >= 5 ? 500.0 : 800.0
            add(checkingId, day: 3, monthOffset: m, amount: -saved, desc: "Transfer to Savings", payee: "Transfer", category: "Transfer")
            add(savingsId, day: 3, monthOffset: m, amount: saved, desc: "Transfer from Checking", payee: "Transfer", category: "Transfer")
            add(savingsId, day: 28, monthOffset: m, amount: 14.22, desc: "Interest", payee: "Interest", category: "Interest")

            // Discretionary spending scales with the season: holidays and summer
            // run hot, January runs lean after the December blowout.
            let seasonal: Double
            switch calMonth {
            case 11, 12: seasonal = 1.9   // holiday shopping + travel
            case 6, 7, 8: seasonal = 1.45 // summer outings and trips
            case 1:      seasonal = 0.7   // post-holiday belt-tightening
            default:     seasonal = 1.0
            }
            let groceryRuns = 4
            let diningRuns = Int((8.0 * seasonal).rounded())
            let transportRuns = Int((4.0 * seasonal).rounded())
            let shoppingRuns = Int((3.0 * seasonal).rounded())

            for _ in 0..<groceryRuns {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -(rng.double(in: 45...160) * seasonal).rounded(to: 2),
                    desc: "Groceries", payee: groceries[rng.int(in: 0..<groceries.count)], category: "Groceries")
            }
            for _ in 0..<diningRuns {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 8...48).rounded(to: 2),
                    desc: "Dining", payee: dining[rng.int(in: 0..<dining.count)], category: "Dining")
            }
            for _ in 0..<transportRuns {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 25...75).rounded(to: 2),
                    desc: "Transport", payee: transport[rng.int(in: 0..<transport.count)], category: "Transport")
            }
            for _ in 0..<shoppingRuns {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 18...210).rounded(to: 2),
                    desc: "Online order", payee: shopping[rng.int(in: 0..<shopping.count)], category: "Shopping")
            }

            // Big one-off purchases pinned to specific months so a few bars
            // spike hard and net cash flow swings negative on those months.
            switch calMonth {
            case 12: add(checkingId, day: 14, monthOffset: m, amount: -1480, desc: "Holiday gifts", payee: "Amazon", category: "Shopping")
            case 7:  add(checkingId, day: 8, monthOffset: m, amount: -2650, desc: "Summer vacation", payee: "Delta Air Lines", category: "Transport")
            case 9:  add(checkingId, day: 11, monthOffset: m, amount: -1999, desc: "New laptop", payee: "Apple Store", category: "Shopping")
            case 3:  add(checkingId, day: 17, monthOffset: m, amount: -845.60, desc: "Car repair", payee: "Firestone", category: "Transport")
            case 5:  add(checkingId, day: 9, monthOffset: m, amount: -620, desc: "Dental work", payee: "Bright Smile Dental", category: "Health")
            case 10: add(checkingId, day: 22, monthOffset: m, amount: -1180, desc: "Living room couch", payee: "West Elm", category: "Shopping")
            default: break
            }
        }

        let accounts = [
            Account(id: checkingId, name: "Everyday Checking", orgName: "Demo Bank",
                    currency: "USD", balance: 8420.55, availableBalance: 8420.55,
                    balanceDate: Int(now.timeIntervalSince1970)),
            Account(id: savingsId, name: "High-Yield Savings", orgName: "Demo Bank",
                    currency: "USD", balance: 41560.18, availableBalance: 41560.18,
                    balanceDate: Int(now.timeIntervalSince1970)),
        ]
        return (accounts, txns)
    }

    /// Generate the demo data and write it to a fresh SQLite file at `url`.
    static func generate(to url: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        let db = try AppDatabase(path: url)
        let (accounts, txns) = make()
        try db.replace(accounts: accounts, transactions: txns)
        try db.recordSync(at: Date())
        try generateMortgage(in: db)
        try generateCategories(in: db, transactions: txns)
        try generateTransfers(in: db, transactions: txns)
    }

    /// Auto-tag the demo's between-account transfers (the monthly checking ->
    /// savings moves) so the Transfer category and its "excluded from totals"
    /// behavior are visible out of the box. Uses the same detection the app runs.
    private static func generateTransfers(in db: AppDatabase, transactions txns: [Transaction]) throws {
        let now = Int(Date().timeIntervalSince1970)
        let detected = TransferDetection.detect(in: txns)
        var seq = 0
        for txn in txns where detected.contains(txn.id) {
            try db.saveExpenseCategory(ExpenseCategory(
                id: "demo-tx-\(seq)", transactionId: txn.id, categoryId: SpendCategory.transferId,
                startDate: nil, endDate: nil, isAuto: true, createdAt: now))
            seq += 1
        }
    }

    /// Seed a few categories and auto-categorize the demo transactions by their
    /// synthetic category string. One expense is tagged manually to show the
    /// manual-versus-auto distinction (a sparkle marks auto links in the UI).
    private static func generateCategories(in db: AppDatabase, transactions txns: [Transaction]) throws {
        let now = Int(Date().timeIntervalSince1970)
        // (display name, color, which SimpleFIN category strings map to it)
        let defs: [(String, String, Set<String>)] = [
            ("Groceries", "#22C55E", ["Groceries"]),
            ("Dining", "#F77061", ["Dining"]),
            ("Transport", "#3B82F6", ["Transport"]),
            ("Shopping", "#A855F7", ["Shopping"]),
            ("Housing", "#6366F1", ["Housing", "Rent"]),
            ("Utilities", "#06B6D4", ["Utilities"]),
            ("Subscriptions", "#F5A623", ["Subscriptions"]),
            ("Health", "#EC4899", ["Health"]),
        ]
        var idByName: [String: String] = [:]
        for (i, def) in defs.enumerated() {
            let id = "demo-cat-\(i)"
            idByName[def.0] = id
            try db.saveCategory(SpendCategory(id: id, name: def.0, colorHex: def.1, createdAt: now))
        }
        func categoryId(for source: String?) -> String? {
            guard let source else { return nil }
            for def in defs where def.2.contains(source) { return idByName[def.0] }
            return nil
        }

        var seq = 0
        var taggedManual = false
        for txn in txns where txn.isExpense {
            guard let catId = categoryId(for: txn.category) else { continue }
            // Tag the first grocery expense manually so the demo shows both kinds.
            let manual = !taggedManual && txn.category == "Groceries"
            if manual { taggedManual = true }
            try db.saveExpenseCategory(ExpenseCategory(
                id: "demo-ec-\(seq)", transactionId: txn.id, categoryId: catId,
                startDate: nil, endDate: nil, isAuto: !manual, createdAt: now))
            seq += 1
        }
    }

    /// A demo mortgage that exercises every feature: rate change, home-value
    /// adjustments, an extra principal payment, and linked synced payments.
    private static func generateMortgage(in db: AppDatabase) throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let now = Date()
        func ago(months: Int) -> Int {
            Int((cal.date(byAdding: .month, value: -months, to: now) ?? now).timeIntervalSince1970)
        }

        let m = Mortgage(
            id: "demo-mortgage", name: "South Jordan House",
            address: "1806 W Ikaros Ln, South Jordan, UT 84095",
            zillowUrl: "https://www.zillow.com/homedetails/1806-W-Ikaros-Ln-South-Jordan-UT-84095/248854700_zpid/",
            principal: 300000,
            downKind: "percent", downValue: 20, annualRate: 6.75, termMonths: 360,
            startDate: ago(months: 36),
            paymentPayee: "Sunset Mortgage Co", paymentAmount: -2300,
            paymentAccountId: checkingId,
            createdAt: Int(now.timeIntervalSince1970)
        )
        try db.saveMortgage(m)
        try db.saveRateChange(MortgageRateChange(
            id: "demo-rc1", mortgageId: m.id, effectiveDate: ago(months: 12), annualRate: 6.25))
        try db.saveValuation(HomeValuation(
            id: "demo-v1", mortgageId: m.id, date: ago(months: 14), value: 352000))
        try db.saveValuation(HomeValuation(
            id: "demo-v2", mortgageId: m.id, date: ago(months: 2), value: 372000))
        try db.saveValuation(HomeValuation(
            id: "demo-v3", mortgageId: m.id, date: ago(months: 1), value: 378000, source: "zillow"))
        try db.saveManualTxn(MortgageManualTxn(
            id: "demo-mt1", mortgageId: m.id, date: ago(months: 6), amount: 10000,
            note: "Bonus toward principal"))

        let links = MortgageDetection.matches(try db.transactions(), for: m)
            .map { MortgagePaymentLink(transactionId: $0.id, mortgageId: m.id) }
        try db.addPaymentLinks(links)
    }
}

/// Tiny deterministic RNG so the demo dataset is stable across regenerations
/// (avoids `Math.random`-style nondeterminism in the committed file).
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(in range: Range<Int>) -> Int {
        let span = UInt64(range.count)
        return range.lowerBound + Int(next() % span)
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9007199254740992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
