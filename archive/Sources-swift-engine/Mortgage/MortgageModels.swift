import Foundation
import GRDB

/// A mortgage. The user enters a few facts (loan amount, down payment, rate,
/// term, start date) and Phinny computes the whole amortization - no need to
/// log individual payments. Stored in its own tables that sync never touches.
struct Mortgage: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    /// Optional property address (native autocomplete; display + reference).
    var address: String? = nil
    /// Optional Zillow property URL (the homedetails/.../<zpid>_zpid/ link).
    /// When set, "Update from Zillow" scrapes this exact page - far more
    /// reliable than resolving an address.
    var zillowUrl: String? = nil
    /// The loan amount borrowed (the "mortgage amount").
    var principal: Double
    /// "percent" or "amount" - how `downValue` is interpreted.
    var downKind: String
    var downValue: Double
    /// Base annual interest rate as a percentage, e.g. 6.5. Rate changes over
    /// time are stored separately (see MortgageRateChange).
    var annualRate: Double
    var termMonths: Int
    /// Epoch seconds of the first scheduled payment / origination.
    var startDate: Int
    /// Signature of the synced transaction used as the recurring payment, set
    /// when the user marks an expense as this mortgage's payment. Auto-detection
    /// links every expense on `paymentAccountId` whose title matches
    /// `paymentPayee` (account + title, not amount). `paymentAccountId` is nil for
    /// older links / amount-only suggestions, in which case the account is ignored.
    var paymentPayee: String?
    var paymentAmount: Double?
    var paymentAccountId: String? = nil
    var createdAt: Int

    static let databaseTableName = "mortgage"

    enum DownKind: String { case percent, amount }
    var down: DownKind { DownKind(rawValue: downKind) ?? .amount }
    var start: Date { Date(timeIntervalSince1970: TimeInterval(startDate)) }

    /// Down payment as a dollar amount, derived from the loan + down-payment input.
    var downAmount: Double {
        switch down {
        case .amount:
            return downValue
        case .percent:
            return max(0, purchasePrice - principal)
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

/// A change to the interest rate effective from a date (ARM reset / refinance).
/// The engine re-amortizes the remaining balance over the remaining term.
struct MortgageRateChange: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var mortgageId: String
    var effectiveDate: Int
    var annualRate: Double

    static let databaseTableName = "mortgage_rate_change"
    var date: Date { Date(timeIntervalSince1970: TimeInterval(effectiveDate)) }
    var monthlyRate: Double { annualRate / 100 / 12 }
}

/// A recorded home value at a point in time. Phinny carries the most recent
/// valuation forward to value the home (and your equity) over time.
struct HomeValuation: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var mortgageId: String
    var date: Int
    var value: Double
    /// Where this value came from: nil/"manual" for hand-entered, "zillow" for
    /// an automated Zillow lookup.
    var source: String? = nil

    static let databaseTableName = "home_valuation"
    var asDate: Date { Date(timeIntervalSince1970: TimeInterval(date)) }
    var isAutomated: Bool { source != nil && source != "manual" }
}

/// A manual transaction attached to a mortgage - typically an extra payment
/// toward principal. Lives in its own table so a sync never deletes it.
struct MortgageManualTxn: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var mortgageId: String
    var date: Int
    /// Positive dollars applied to principal (beyond the scheduled payment).
    var amount: Double
    var note: String?

    static let databaseTableName = "mortgage_manual_txn"
    var asDate: Date { Date(timeIntervalSince1970: TimeInterval(date)) }
}

/// Links a synced transaction to a mortgage as one of its payments. Keyed by
/// the transaction id, which is stable across syncs.
struct MortgagePaymentLink: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var transactionId: String
    var mortgageId: String

    static let databaseTableName = "mortgage_payment_link"
    var id: String { transactionId }
}
