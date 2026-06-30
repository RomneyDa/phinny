import Foundation
import GRDB

/// A bank/credit account, as stored in SQLite. Mirrors a SimpleFIN account.
struct Account: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var orgName: String
    var currency: String
    var balance: Double
    var availableBalance: Double?
    /// Epoch seconds of the balance reading.
    var balanceDate: Int?
    /// User chose to hide this account from the dashboard totals/charts. Set in
    /// the SimpleFIN tab; preserved across syncs (see `AppDatabase.replace`).
    var hidden: Bool = false

    static let databaseTableName = "account"
}

/// A single transaction, as stored in SQLite. Mirrors a SimpleFIN transaction.
///
/// `amount` follows the SimpleFIN sign convention: negative = money out
/// (spending), positive = money in (income).
struct Transaction: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    /// Globally-unique key ("accountId|providerId"), used as the SQLite primary
    /// key and SwiftUI identity. SimpleFIN transaction ids are only unique
    /// *within* an account (the demo bridge even reuses them across accounts),
    /// so we namespace by account to avoid collisions on upsert.
    var id: String
    /// The original SimpleFIN transaction id (kept for debugging / future dedup).
    var providerId: String
    var accountId: String
    /// Epoch seconds when the transaction posted.
    var posted: Int
    var amount: Double
    var descriptionText: String
    var payee: String?
    var memo: String?
    var category: String?
    var pending: Bool

    static let databaseTableName = "transaction_row"

    var date: Date { Date(timeIntervalSince1970: TimeInterval(posted)) }
    var isIncome: Bool { amount > 0 }
    var isExpense: Bool { amount < 0 }

    /// Best human label for grouping/charts: category, else payee, else a
    /// trimmed description.
    var groupLabel: String {
        if let c = category, !c.isEmpty { return c }
        if let p = payee, !p.isEmpty { return p }
        let d = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? "Uncategorized" : d
    }
}
