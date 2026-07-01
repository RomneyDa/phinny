import Foundation

/// A mortgage. The user enters a few facts (loan amount, down payment, rate,
/// term, start date) and the phinny engine computes the whole amortization.
/// Decoded from / encoded to the daemon's snake_case JSON.
struct Mortgage: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Optional property address (display + reference).
    var address: String? = nil
    /// Optional Zillow property URL (the homedetails/.../<zpid>_zpid/ link).
    var zillowUrl: String? = nil
    /// The loan amount borrowed.
    var principal: Double
    /// "percent" or "amount" - how `downValue` is interpreted.
    var downKind: String
    var downValue: Double
    /// Base annual interest rate as a percentage, e.g. 6.5.
    var annualRate: Double
    var termMonths: Int
    /// Epoch seconds of the first scheduled payment / origination.
    var startDate: Int
    var paymentPayee: String?
    var paymentAmount: Double?
    var paymentAccountId: String? = nil
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, name, address, principal
        case zillowUrl = "zillow_url"
        case downKind = "down_kind"
        case downValue = "down_value"
        case annualRate = "annual_rate"
        case termMonths = "term_months"
        case startDate = "start_date"
        case paymentPayee = "payment_payee"
        case paymentAmount = "payment_amount"
        case paymentAccountId = "payment_account_id"
        case createdAt = "created_at"
    }

    enum DownKind: String { case percent, amount }
    var down: DownKind { DownKind(rawValue: downKind) ?? .amount }
    var start: Date { Date(timeIntervalSince1970: TimeInterval(startDate)) }

    var downAmount: Double {
        switch down {
        case .amount: return downValue
        case .percent: return max(0, purchasePrice - principal)
        }
    }

    /// Original home purchase price = loan + down payment.
    var purchasePrice: Double {
        switch down {
        case .amount:
            return principal + downValue
        case .percent:
            let p = min(max(downValue / 100, 0), 0.95)
            return p >= 1 ? principal : principal / (1 - p)
        }
    }

    var monthlyRate: Double { annualRate / 100 / 12 }
}

struct MortgageRateChange: Codable, Identifiable, Hashable {
    var id: String
    var mortgageId: String
    var effectiveDate: Int
    var annualRate: Double

    enum CodingKeys: String, CodingKey {
        case id
        case mortgageId = "mortgage_id"
        case effectiveDate = "effective_date"
        case annualRate = "annual_rate"
    }
    /// Engine table name, used by `deleteMortgageChild`.
    static let databaseTableName = "mortgage_rate_change"
    var date: Date { Date(timeIntervalSince1970: TimeInterval(effectiveDate)) }
    var monthlyRate: Double { annualRate / 100 / 12 }
}

struct HomeValuation: Codable, Identifiable, Hashable {
    var id: String
    var mortgageId: String
    var date: Int
    var value: Double
    /// nil/"manual" for hand-entered, "zillow" for an automated lookup.
    var source: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, date, value, source
        case mortgageId = "mortgage_id"
    }
    static let databaseTableName = "home_valuation"
    var asDate: Date { Date(timeIntervalSince1970: TimeInterval(date)) }
    var isAutomated: Bool { source != nil && source != "manual" }
}

struct MortgageManualTxn: Codable, Identifiable, Hashable {
    var id: String
    var mortgageId: String
    var date: Int
    var amount: Double
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id, date, amount, note
        case mortgageId = "mortgage_id"
    }
    static let databaseTableName = "mortgage_manual_txn"
    var asDate: Date { Date(timeIntervalSince1970: TimeInterval(date)) }
}

struct MortgagePaymentLink: Codable, Identifiable, Hashable {
    var transactionId: String
    var mortgageId: String

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case mortgageId = "mortgage_id"
    }
    var id: String { transactionId }
}
