import Foundation
import GRDB

/// A spending category. Created by the user today; in the future an AI
/// auto-categorizer can create and manage these too (same structure, no special
/// casing). Categories are global: a category is not tied to one transaction.
struct SpendCategory: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    /// Hex color (e.g. "#6366F1") used for the chip + chart segment.
    var colorHex: String
    var createdAt: Int
    /// When true, transactions in this category do not count toward income or
    /// spending (they are money moved between your own accounts). The permanent
    /// "Transfer" category has this set; the column is generic so any category
    /// could be flagged the same way.
    var isTransfer: Bool = false

    // Named "category" in SQLite; the Swift type avoids the bare name `Category`,
    // which collides with a clang-imported C symbol.
    static let databaseTableName = "category"

    /// Stable id of the permanent, hard-coded Transfer category (seeded by
    /// migration v6). It is never deletable.
    static let transferId = "transfer"

    /// True for built-in categories the user cannot delete.
    var isPermanent: Bool { id == Self.transferId }
}

/// Marks a transaction as explicitly "not a transfer" so auto-detection does not
/// re-tag it. Marking a transaction AS a transfer reuses the normal manual
/// `ExpenseCategory` link to the Transfer category; only the negative decision
/// needs its own record.
struct TransferExclusion: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var transactionId: String
    var createdAt: Int

    var id: String { transactionId }
    static let databaseTableName = "transfer_exclusion"
}

/// Links a transaction (expense) to a `Category`. This is the structure both
/// manual tagging and future AI auto-categorization share.
///
/// - `isAuto` records whether the link was made by auto-categorization. A manual
///   link (isAuto = false) is never overridden by auto-categorization.
/// - `startDate`/`endDate` are an optional effective window (epoch seconds). Both
///   nil (the default) means the link always applies. A window lets you scope a
///   categorization in time so non-overlapping links never conflict.
///
/// Conflict rule: two links conflict only when they share the same
/// `transactionId` AND the same `categoryId` AND their date ranges overlap. So
/// the same expense can belong to several categories, and the same
/// expense+category pair can exist across non-overlapping windows.
struct ExpenseCategory: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var transactionId: String
    var categoryId: String
    /// Effective window start (epoch seconds), nil = open (no lower bound).
    var startDate: Int?
    /// Effective window end (epoch seconds), nil = open (no upper bound).
    var endDate: Int?
    /// True if created by auto-categorization, false if set manually.
    var isAuto: Bool
    var createdAt: Int

    static let databaseTableName = "expense_category"

    var startDateValue: Date? { startDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var endDateValue: Date? { endDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var hasWindow: Bool { startDate != nil || endDate != nil }

    /// Does this link apply to a transaction posted at `posted` (epoch seconds)?
    /// A link with no window always applies; otherwise the posted instant must
    /// fall inside [startDate, endDate].
    func applies(toPosted posted: Int) -> Bool {
        if let s = startDate, posted < s { return false }
        if let e = endDate, posted > e { return false }
        return true
    }

    /// Do two effective windows overlap? nil bounds are treated as open
    /// (-infinity / +infinity), so two windowless links always overlap.
    static func windowsOverlap(_ a: ExpenseCategory, _ b: ExpenseCategory) -> Bool {
        let lo1 = a.startDate ?? Int.min, hi1 = a.endDate ?? Int.max
        let lo2 = b.startDate ?? Int.min, hi2 = b.endDate ?? Int.max
        return max(lo1, lo2) <= min(hi1, hi2)
    }
}
