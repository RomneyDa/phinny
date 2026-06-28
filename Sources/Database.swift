import Foundation
import GRDB

/// SQLite storage for Phinny, backed by GRDB. The database file lives at
/// ~/.phinny/phinny.sqlite. One `AppDatabase` is created at launch and shared.
///
/// Schema (see `migrator`):
///   account         - one row per synced account
///   transaction_row - one row per synced transaction (named to avoid the
///                     SQL reserved word "transaction")
///   meta            - key/value scratch table (e.g. last_sync_at)
final class AppDatabase {
    private let dbQueue: DatabaseQueue

    init(path: URL = Paths.databaseFile) throws {
        try Paths.ensureConfigDir()
        dbQueue = try DatabaseQueue(path: path.path)
        try migrator.migrate(dbQueue)
    }

    /// In-memory database for tests/previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(memory: ())
    }

    private init(memory: Void) throws {
        dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("orgName", .text).notNull()
                t.column("currency", .text).notNull()
                t.column("balance", .double).notNull()
                t.column("availableBalance", .double)
                t.column("balanceDate", .integer)
            }
            try db.create(table: "transaction_row") { t in
                t.primaryKey("id", .text)
                t.column("providerId", .text).notNull()
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("posted", .integer).notNull().indexed()
                t.column("amount", .double).notNull()
                t.column("descriptionText", .text).notNull()
                t.column("payee", .text)
                t.column("memo", .text)
                t.column("category", .text)
                t.column("pending", .boolean).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // v2: mortgages and their adjustments. These tables are never touched by
        // a sync, so manual entries (e.g. extra principal payments) survive.
        migrator.registerMigration("v2") { db in
            try db.create(table: "mortgage") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("principal", .double).notNull()
                t.column("downKind", .text).notNull()
                t.column("downValue", .double).notNull()
                t.column("annualRate", .double).notNull()
                t.column("termMonths", .integer).notNull()
                t.column("startDate", .integer).notNull()
                t.column("paymentPayee", .text)
                t.column("paymentAmount", .double)
                t.column("createdAt", .integer).notNull()
            }
            try db.create(table: "mortgage_rate_change") { t in
                t.primaryKey("id", .text)
                t.column("mortgageId", .text).notNull()
                    .indexed().references("mortgage", onDelete: .cascade)
                t.column("effectiveDate", .integer).notNull()
                t.column("annualRate", .double).notNull()
            }
            try db.create(table: "home_valuation") { t in
                t.primaryKey("id", .text)
                t.column("mortgageId", .text).notNull()
                    .indexed().references("mortgage", onDelete: .cascade)
                t.column("date", .integer).notNull()
                t.column("value", .double).notNull()
            }
            try db.create(table: "mortgage_manual_txn") { t in
                t.primaryKey("id", .text)
                t.column("mortgageId", .text).notNull()
                    .indexed().references("mortgage", onDelete: .cascade)
                t.column("date", .integer).notNull()
                t.column("amount", .double).notNull()
                t.column("note", .text)
            }
            try db.create(table: "mortgage_payment_link") { t in
                t.primaryKey("transactionId", .text)
                t.column("mortgageId", .text).notNull()
                    .indexed().references("mortgage", onDelete: .cascade)
            }
        }
        // v3: property address (for Zillow lookups) + valuation source.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "mortgage") { t in
                t.add(column: "address", .text)
            }
            try db.alter(table: "home_valuation") { t in
                t.add(column: "source", .text)
            }
        }
        // v4: a direct Zillow property URL for reliable Zestimate scraping.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "mortgage") { t in
                t.add(column: "zillowUrl", .text)
            }
        }
        return migrator
    }

    // MARK: - Writes

    /// Upsert the synced accounts + transactions in a single transaction.
    func replace(accounts: [Account], transactions: [Transaction]) throws {
        try dbQueue.write { db in
            for account in accounts { try account.save(db) }
            for txn in transactions { try txn.save(db) }
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) " +
                     "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Reads

    func accounts() throws -> [Account] {
        try dbQueue.read { db in
            try Account.order(Column("name")).fetchAll(db)
        }
    }

    /// All transactions, newest first.
    func transactions() throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction.order(Column("posted").desc).fetchAll(db)
        }
    }

    func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func transactionCount() throws -> Int {
        try dbQueue.read { db in try Transaction.fetchCount(db) }
    }

    // MARK: - Mortgages

    func mortgages() throws -> [Mortgage] {
        try dbQueue.read { db in try Mortgage.order(Column("createdAt")).fetchAll(db) }
    }
    func saveMortgage(_ m: Mortgage) throws {
        try dbQueue.write { db in try m.save(db) }
    }
    func deleteMortgage(id: String) throws {
        _ = try dbQueue.write { db in try Mortgage.deleteOne(db, key: id) }
    }

    func rateChanges() throws -> [MortgageRateChange] {
        try dbQueue.read { db in try MortgageRateChange.order(Column("effectiveDate")).fetchAll(db) }
    }
    func saveRateChange(_ r: MortgageRateChange) throws {
        try dbQueue.write { db in try r.save(db) }
    }

    func valuations() throws -> [HomeValuation] {
        try dbQueue.read { db in try HomeValuation.order(Column("date")).fetchAll(db) }
    }
    func saveValuation(_ v: HomeValuation) throws {
        try dbQueue.write { db in try v.save(db) }
    }

    func manualTxns() throws -> [MortgageManualTxn] {
        try dbQueue.read { db in try MortgageManualTxn.order(Column("date")).fetchAll(db) }
    }
    func saveManualTxn(_ t: MortgageManualTxn) throws {
        try dbQueue.write { db in try t.save(db) }
    }

    /// Delete any row from a mortgage child table by id (rate change, valuation,
    /// manual txn). `table` is the GRDB table name.
    func deleteMortgageChild(table: String, id: String) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
        }
    }

    func paymentLinks() throws -> [MortgagePaymentLink] {
        try dbQueue.read { db in try MortgagePaymentLink.fetchAll(db) }
    }
    func addPaymentLinks(_ links: [MortgagePaymentLink]) throws {
        try dbQueue.write { db in for l in links { try l.save(db) } }
    }
    func removePaymentLinks(mortgageId: String) throws {
        _ = try dbQueue.write { db in
            try MortgagePaymentLink.filter(Column("mortgageId") == mortgageId).deleteAll(db)
        }
    }

    // MARK: - Meta helpers

    private static let lastSyncKey = "last_sync_at"

    func lastSync() -> Date? {
        guard let raw = try? meta(Self.lastSyncKey),
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func recordSync(at date: Date) throws {
        try setMeta(Self.lastSyncKey, String(date.timeIntervalSince1970))
    }
}
