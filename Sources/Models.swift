import Foundation

/// A bank/credit account. Decoded from the phinny daemon (snake_case JSON); the
/// daemon owns SQLite storage. Encodable too, for the rare round-trip.
struct Account: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var orgName: String
    var currency: String
    var balance: Double
    var availableBalance: Double?
    /// Epoch seconds of the balance reading.
    var balanceDate: Int?
    /// User chose to hide this account from the dashboard totals/charts.
    var hidden: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, currency, balance, hidden
        case orgName = "org_name"
        case availableBalance = "available_balance"
        case balanceDate = "balance_date"
    }
}

/// A single transaction. `amount` follows the SimpleFIN sign convention:
/// negative = money out (spending), positive = money in (income).
struct Transaction: Codable, Identifiable, Hashable {
    var id: String
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

    enum CodingKeys: String, CodingKey {
        case id, posted, amount, payee, memo, category, pending
        case providerId = "provider_id"
        case accountId = "account_id"
        case descriptionText = "description"
    }

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
