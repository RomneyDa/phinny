import Foundation

/// A spending category. Global (not tied to one transaction). Decoded from /
/// encoded to the daemon's snake_case JSON.
struct SpendCategory: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Hex color (e.g. "#6366F1") used for the chip + chart segment.
    var colorHex: String
    var createdAt: Int
    /// When true, transactions in this category do not count toward income or
    /// spending (money moved between your own accounts).
    var isTransfer: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name
        case colorHex = "color_hex"
        case createdAt = "created_at"
        case isTransfer = "is_transfer"
    }

    /// Stable id of the permanent, hard-coded Transfer category.
    static let transferId = "transfer"

    /// True for built-in categories the user cannot delete.
    var isPermanent: Bool { id == Self.transferId }
}

/// Marks a transaction as explicitly "not a transfer" so auto-detection does not
/// re-tag it.
struct TransferExclusion: Codable, Identifiable, Hashable {
    var transactionId: String
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case createdAt = "created_at"
    }
    var id: String { transactionId }
}

/// Links a transaction (expense) to a category. Shared by manual tagging and
/// auto-categorization (distinguished by `isAuto`). An optional effective window
/// (`startDate`/`endDate`) lets the same expense+category repeat across
/// non-overlapping windows.
struct ExpenseCategory: Codable, Identifiable, Hashable {
    var id: String
    var transactionId: String
    var categoryId: String
    var startDate: Int?
    var endDate: Int?
    var isAuto: Bool
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case transactionId = "transaction_id"
        case categoryId = "category_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case isAuto = "is_auto"
        case createdAt = "created_at"
    }

    var startDateValue: Date? { startDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var endDateValue: Date? { endDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var hasWindow: Bool { startDate != nil || endDate != nil }

    /// Does this link apply to a transaction posted at `posted` (epoch seconds)?
    func applies(toPosted posted: Int) -> Bool {
        if let s = startDate, posted < s { return false }
        if let e = endDate, posted > e { return false }
        return true
    }

    /// Do two effective windows overlap? nil bounds are open (-inf / +inf).
    static func windowsOverlap(_ a: ExpenseCategory, _ b: ExpenseCategory) -> Bool {
        let lo1 = a.startDate ?? Int.min, hi1 = a.endDate ?? Int.max
        let lo2 = b.startDate ?? Int.min, hi2 = b.endDate ?? Int.max
        return max(lo1, lo2) <= min(hi1, hi2)
    }
}
