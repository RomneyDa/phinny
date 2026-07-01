import Foundation

/// Pure aggregation helpers that turn raw transactions into the series the
/// charts render. No I/O - easy to read, easy to test.
enum Analytics {

    /// Income vs. spending for one calendar month.
    struct MonthlyFlow: Identifiable {
        let month: Date            // first day of the month
        let income: Double         // sum of positive amounts
        let expense: Double        // sum of |negative amounts|
        var id: Date { month }
        var net: Double { income - expense }
    }

    /// Spending grouped by category/merchant.
    struct CategorySpend: Identifiable {
        let label: String
        let amount: Double
        var id: String { label }
    }

    /// Headline numbers for the summary cards.
    struct Summary {
        var totalBalance: Double = 0
        var currentMonthIncome: Double = 0
        var currentMonthExpense: Double = 0
        var transactionCount: Int = 0
        var accountCount: Int = 0
        var currentMonthNet: Double { currentMonthIncome - currentMonthExpense }
    }

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let c = calendar
        return c.date(from: c.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Income/expense per month for the last `months` months (oldest first),
    /// including empty months so the chart has a continuous axis.
    static func monthlyFlows(_ transactions: [Transaction], months: Int = 12) -> [MonthlyFlow] {
        let cal = calendar
        let thisMonth = startOfMonth(Date())

        // Build the ordered list of buckets we want to show.
        var buckets: [Date] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            if let m = cal.date(byAdding: .month, value: -offset, to: thisMonth) {
                buckets.append(m)
            }
        }
        let earliest = buckets.first ?? thisMonth

        var income: [Date: Double] = [:]
        var expense: [Date: Double] = [:]
        for txn in transactions where txn.date >= earliest {
            let key = startOfMonth(txn.date)
            if txn.amount >= 0 { income[key, default: 0] += txn.amount }
            else { expense[key, default: 0] += -txn.amount }
        }

        return buckets.map { month in
            MonthlyFlow(month: month, income: income[month] ?? 0, expense: expense[month] ?? 0)
        }
    }

    /// Top spending groups (category → merchant → description) within the last
    /// `days` days. Anything past `topN` is collapsed into "Other".
    static func topSpending(_ transactions: [Transaction], days: Int = 30, topN: Int = 7,
                            label: (Transaction) -> String = { $0.groupLabel }) -> [CategorySpend] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        var totals: [String: Double] = [:]
        for txn in transactions where txn.isExpense && txn.date >= cutoff {
            totals[label(txn), default: 0] += -txn.amount
        }
        let sorted = totals.map { CategorySpend(label: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        guard sorted.count > topN else { return sorted }
        let top = Array(sorted.prefix(topN))
        let otherTotal = sorted.dropFirst(topN).reduce(0) { $0 + $1.amount }
        return top + [CategorySpend(label: "Other", amount: otherTotal)]
    }

    static func summary(accounts: [Account], transactions: [Transaction]) -> Summary {
        var s = Summary()
        s.accountCount = accounts.count
        s.transactionCount = transactions.count
        s.totalBalance = accounts.reduce(0) { $0 + $1.balance }

        let monthStart = startOfMonth(Date())
        for txn in transactions where txn.date >= monthStart {
            if txn.amount >= 0 { s.currentMonthIncome += txn.amount }
            else { s.currentMonthExpense += -txn.amount }
        }
        return s
    }
}
