import Foundation

/// Amortization value types + the one pure formula the editor uses live for a
/// live payment preview. The full schedule/summary math now runs in the phinny
/// Go engine (mortgage package); `Point`/`Summary` are the decoded results it
/// returns. Kept under the `MortgageEngine` namespace so the views are unchanged.
enum MortgageEngine {

    /// One month of the amortization schedule.
    struct Point: Identifiable, Decodable {
        let date: Date
        let balance: Double
        let payment: Double
        let interest: Double
        let principal: Double
        let extraPrincipal: Double
        let cumulativeInterest: Double
        let cumulativePrincipal: Double
        let homeValue: Double
        var id: Date { date }
        var equity: Double { homeValue - balance }

        enum CodingKeys: String, CodingKey {
            case date, balance, payment, interest, principal
            case extraPrincipal = "extra_principal"
            case cumulativeInterest = "cumulative_interest"
            case cumulativePrincipal = "cumulative_principal"
            case homeValue = "home_value"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = Date(timeIntervalSince1970: TimeInterval(try c.decode(Int.self, forKey: .date)))
            balance = try c.decode(Double.self, forKey: .balance)
            payment = try c.decode(Double.self, forKey: .payment)
            interest = try c.decode(Double.self, forKey: .interest)
            principal = try c.decode(Double.self, forKey: .principal)
            extraPrincipal = try c.decode(Double.self, forKey: .extraPrincipal)
            cumulativeInterest = try c.decode(Double.self, forKey: .cumulativeInterest)
            cumulativePrincipal = try c.decode(Double.self, forKey: .cumulativePrincipal)
            homeValue = try c.decode(Double.self, forKey: .homeValue)
        }
    }

    /// Headline numbers as of a given date.
    struct Summary: Decodable {
        var currentBalance: Double = 0
        var monthlyPayment: Double = 0
        var homeValue: Double = 0
        var equity: Double = 0
        var interestPaidToDate: Double = 0
        var principalPaidToDate: Double = 0
        var originalPrincipal: Double = 0
        var purchasePrice: Double = 0
        var totalInterestOverLife: Double = 0
        var payoffDate: Date?
        var nextPaymentDate: Date?
        var percentPaidOff: Double = 0

        init() {}

        enum CodingKeys: String, CodingKey {
            case currentBalance = "current_balance"
            case monthlyPayment = "monthly_payment"
            case homeValue = "home_value"
            case equity
            case interestPaidToDate = "interest_paid_to_date"
            case principalPaidToDate = "principal_paid_to_date"
            case originalPrincipal = "original_principal"
            case purchasePrice = "purchase_price"
            case totalInterestOverLife = "total_interest_over_life"
            case payoffDate = "payoff_date"
            case nextPaymentDate = "next_payment_date"
            case percentPaidOff = "percent_paid_off"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currentBalance = try c.decodeIfPresent(Double.self, forKey: .currentBalance) ?? 0
            monthlyPayment = try c.decodeIfPresent(Double.self, forKey: .monthlyPayment) ?? 0
            homeValue = try c.decodeIfPresent(Double.self, forKey: .homeValue) ?? 0
            equity = try c.decodeIfPresent(Double.self, forKey: .equity) ?? 0
            interestPaidToDate = try c.decodeIfPresent(Double.self, forKey: .interestPaidToDate) ?? 0
            principalPaidToDate = try c.decodeIfPresent(Double.self, forKey: .principalPaidToDate) ?? 0
            originalPrincipal = try c.decodeIfPresent(Double.self, forKey: .originalPrincipal) ?? 0
            purchasePrice = try c.decodeIfPresent(Double.self, forKey: .purchasePrice) ?? 0
            totalInterestOverLife = try c.decodeIfPresent(Double.self, forKey: .totalInterestOverLife) ?? 0
            if let p = try c.decodeIfPresent(Int.self, forKey: .payoffDate) {
                payoffDate = Date(timeIntervalSince1970: TimeInterval(p))
            }
            if let n = try c.decodeIfPresent(Int.self, forKey: .nextPaymentDate) {
                nextPaymentDate = Date(timeIntervalSince1970: TimeInterval(n))
            }
            percentPaidOff = try c.decodeIfPresent(Double.self, forKey: .percentPaidOff) ?? 0
        }
    }

    /// Standard fixed-rate monthly payment for `principal` over `months` at
    /// monthly rate `r`. Pure + instant; used by the editor for a live preview as
    /// the user types loan terms (before anything is saved).
    static func payment(principal: Double, monthlyRate r: Double, months: Int) -> Double {
        guard months > 0 else { return principal }
        guard r > 0 else { return principal / Double(months) }
        let factor = pow(1 + r, Double(months))
        return principal * r * factor / (factor - 1)
    }
}
