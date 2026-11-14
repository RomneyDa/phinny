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
    ///
    /// `totalBalance` is liquid accounts only (credit cards are negative, so
    /// they already net out). `netWorth` adds home equity, which the engine
    /// takes from the amortization math rather than any account row.
    struct Summary: Decodable {
        var totalBalance: Double = 0
        var mortgageEquity: Double = 0
        var netWorth: Double = 0
        var currentMonthIncome: Double = 0
        var currentMonthExpense: Double = 0
        var transactionCount: Int = 0
        var accountCount: Int = 0
        var currentMonthNet: Double { currentMonthIncome - currentMonthExpense }
        /// True when there is equity to attribute, so the view can skip the
        /// breakdown line for users with no mortgage.
        var hasMortgageEquity: Bool { mortgageEquity != 0 }

        init() {}

        enum CodingKeys: String, CodingKey {
            case totalBalance = "total_balance"
            case mortgageEquity = "mortgage_equity"
            case netWorth = "net_worth"
            case currentMonthIncome = "current_month_income"
            case currentMonthExpense = "current_month_expense"
            case transactionCount = "transaction_count"
            case accountCount = "account_count"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalBalance = try c.decodeIfPresent(Double.self, forKey: .totalBalance) ?? 0
            mortgageEquity = try c.decodeIfPresent(Double.self, forKey: .mortgageEquity) ?? 0
            currentMonthIncome = try c.decodeIfPresent(Double.self, forKey: .currentMonthIncome) ?? 0
            currentMonthExpense = try c.decodeIfPresent(Double.self, forKey: .currentMonthExpense) ?? 0
            transactionCount = try c.decodeIfPresent(Int.self, forKey: .transactionCount) ?? 0
            accountCount = try c.decodeIfPresent(Int.self, forKey: .accountCount) ?? 0
            // Fall back to balances plus equity so an older engine that does
            // not send net_worth still renders a correct card.
            netWorth = try c.decodeIfPresent(Double.self, forKey: .netWorth)
                ?? (totalBalance + mortgageEquity)
        }
    }

    /// Net worth at the end of one month, split into the two parts it is made
    /// of so the chart can stack them.
    struct NetWorthPoint: Identifiable, Decodable {
        let month: Date            // first day of the month
        let accounts: Double
        let equity: Double
        let netWorth: Double
        var id: Date { month }

        enum CodingKeys: String, CodingKey {
            case month, accounts, equity
            case netWorth = "net_worth"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let epoch = try c.decode(Int.self, forKey: .month)
            month = Date(timeIntervalSince1970: TimeInterval(epoch))
            accounts = try c.decodeIfPresent(Double.self, forKey: .accounts) ?? 0
            equity = try c.decodeIfPresent(Double.self, forKey: .equity) ?? 0
            netWorth = try c.decodeIfPresent(Double.self, forKey: .netWorth) ?? (accounts + equity)
        }
    }

    /// One account's slice of the summary, so the dashboard can show where a
    /// balance sits instead of only the total. Monthly figures use the same
    /// transfer-filtered transactions as `Summary`.
    struct AccountRollup: Identifiable, Decodable {
        var accountId: String = ""
        var name: String = ""
        var orgName: String = ""
        var currency: String = "USD"
        var balance: Double = 0
        var currentMonthIncome: Double = 0
        var currentMonthExpense: Double = 0
        var currentMonthNet: Double = 0
        var transactionCount: Int = 0

        var id: String { accountId }

        enum CodingKeys: String, CodingKey {
            case accountId = "account_id"
            case name
            case orgName = "org_name"
            case currency
            case balance
            case currentMonthIncome = "current_month_income"
            case currentMonthExpense = "current_month_expense"
            case currentMonthNet = "current_month_net"
            case transactionCount = "transaction_count"
        }
    }

    /// The whole `dashboard` payload.
    struct DashboardData: Decodable {
        var summary: Summary
        var accounts: [AccountRollup] = []
        var monthlyFlows: [MonthlyFlow]
        var netWorthTrend: [NetWorthPoint] = []
        var topSpending: [CategorySpend]

        enum CodingKeys: String, CodingKey {
            case summary
            case accounts
            case monthlyFlows = "monthly_flows"
            case netWorthTrend = "net_worth_trend"
            case topSpending = "top_spending"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = try c.decode(Summary.self, forKey: .summary)
            // Optional so an older engine without per-account rollups decodes.
            accounts = try c.decodeIfPresent([AccountRollup].self, forKey: .accounts) ?? []
            monthlyFlows = try c.decode([MonthlyFlow].self, forKey: .monthlyFlows)
            netWorthTrend = try c.decodeIfPresent([NetWorthPoint].self, forKey: .netWorthTrend) ?? []
            topSpending = try c.decode([CategorySpend].self, forKey: .topSpending)
        }
    }
}
