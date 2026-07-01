import Foundation

/// Chart/series value types. The aggregation math now lives in the phinny Go
/// engine (analytics package); these are the decoded results it returns in the
/// `dashboard` payload. Kept under the `Analytics` namespace so the views are
/// unchanged.
enum Analytics {

    /// Income vs. spending for one calendar month.
    struct MonthlyFlow: Identifiable, Decodable {
        let month: Date            // first day of the month
        let income: Double
        let expense: Double
        var id: Date { month }
        var net: Double { income - expense }

        enum CodingKeys: String, CodingKey { case month, income, expense }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let epoch = try c.decode(Int.self, forKey: .month)
            month = Date(timeIntervalSince1970: TimeInterval(epoch))
            income = try c.decode(Double.self, forKey: .income)
            expense = try c.decode(Double.self, forKey: .expense)
        }
    }

    /// Spending grouped by category/merchant.
    struct CategorySpend: Identifiable, Decodable {
        let label: String
        let amount: Double
        var id: String { label }
    }

    /// Headline numbers for the summary cards.
    struct Summary: Decodable {
        var totalBalance: Double = 0
        var currentMonthIncome: Double = 0
        var currentMonthExpense: Double = 0
        var transactionCount: Int = 0
        var accountCount: Int = 0
        var currentMonthNet: Double { currentMonthIncome - currentMonthExpense }

        init() {}

        enum CodingKeys: String, CodingKey {
            case totalBalance = "total_balance"
            case currentMonthIncome = "current_month_income"
            case currentMonthExpense = "current_month_expense"
            case transactionCount = "transaction_count"
            case accountCount = "account_count"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalBalance = try c.decodeIfPresent(Double.self, forKey: .totalBalance) ?? 0
            currentMonthIncome = try c.decodeIfPresent(Double.self, forKey: .currentMonthIncome) ?? 0
            currentMonthExpense = try c.decodeIfPresent(Double.self, forKey: .currentMonthExpense) ?? 0
            transactionCount = try c.decodeIfPresent(Int.self, forKey: .transactionCount) ?? 0
            accountCount = try c.decodeIfPresent(Int.self, forKey: .accountCount) ?? 0
        }
    }

    /// The whole `dashboard` payload.
    struct DashboardData: Decodable {
        var summary: Summary
        var monthlyFlows: [MonthlyFlow]
        var topSpending: [CategorySpend]

        enum CodingKeys: String, CodingKey {
            case summary
            case monthlyFlows = "monthly_flows"
            case topSpending = "top_spending"
        }
    }
}
