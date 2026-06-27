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
        let groceries = ["Whole Foods", "Trader Joe's", "Safeway"]
        let dining = ["Chipotle", "Blue Bottle Coffee", "Sushi Ya", "Local Thai"]
        let transport = ["Shell", "Uber", "Chevron", "BART"]
        let shopping = ["Amazon", "Target", "Apple Store"]

        for m in 0..<12 {
            // Income: biweekly payroll.
            add(checkingId, day: 1, monthOffset: m, amount: 2600, desc: "Payroll - Acme Corp", payee: "Acme Corp", category: "Income")
            add(checkingId, day: 15, monthOffset: m, amount: 2600, desc: "Payroll - Acme Corp", payee: "Acme Corp", category: "Income")

            // Fixed monthly bills.
            add(checkingId, day: 2, monthOffset: m, amount: -2200, desc: "Rent", payee: "Sunset Apartments", category: "Rent")
            add(checkingId, day: 10, monthOffset: m, amount: -132.40, desc: "Electric & Gas", payee: "PG&E", category: "Utilities")
            add(checkingId, day: 10, monthOffset: m, amount: -79.99, desc: "Internet", payee: "Comcast", category: "Utilities")
            add(checkingId, day: 5, monthOffset: m, amount: -15.49, desc: "Netflix", payee: "Netflix", category: "Subscriptions")
            add(checkingId, day: 5, monthOffset: m, amount: -11.99, desc: "Spotify", payee: "Spotify", category: "Subscriptions")
            add(checkingId, day: 6, monthOffset: m, amount: -45, desc: "Gym membership", payee: "Iron Works Gym", category: "Health")

            // Savings: transfer + interest.
            add(checkingId, day: 3, monthOffset: m, amount: -500, desc: "Transfer to Savings", payee: "Transfer", category: "Transfer")
            add(savingsId, day: 3, monthOffset: m, amount: 500, desc: "Transfer from Checking", payee: "Transfer", category: "Transfer")
            add(savingsId, day: 28, monthOffset: m, amount: 14.22, desc: "Interest", payee: "Interest", category: "Interest")

            // Variable spending spread through the month.
            for _ in 0..<4 {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 45...160).rounded(to: 2),
                    desc: "Groceries", payee: groceries[rng.int(in: 0..<groceries.count)], category: "Groceries")
            }
            for _ in 0..<8 {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 8...48).rounded(to: 2),
                    desc: "Dining", payee: dining[rng.int(in: 0..<dining.count)], category: "Dining")
            }
            for _ in 0..<4 {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 25...75).rounded(to: 2),
                    desc: "Transport", payee: transport[rng.int(in: 0..<transport.count)], category: "Transport")
            }
            for _ in 0..<3 {
                let day = 1 + rng.int(in: 0..<28)
                add(checkingId, day: day, monthOffset: m, amount: -rng.double(in: 18...210).rounded(to: 2),
                    desc: "Online order", payee: shopping[rng.int(in: 0..<shopping.count)], category: "Shopping")
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
