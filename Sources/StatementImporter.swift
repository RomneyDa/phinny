import Foundation

/// Parses an Apple Card statement export into Phinny's storage models.
///
/// Apple Card cannot be linked through SimpleFIN/Plaid (Apple blocks
/// aggregators), so the only reliable feed is the file a user exports from the
/// iPhone Wallet app (Wallet > Apple Card > Card Balance > a closed monthly
/// statement > Export Transactions). Apple offers CSV, OFX, QFX, and QBO.
///
/// This type is intentionally PURE (like `Analytics`): hand it the file bytes
/// and it returns a `SimpleFINClient.FetchResult` ready for
/// `AppDatabase.replace(...)`. No I/O, no app state - trivially testable.
///
/// Imported rows reuse the SimpleFIN sign convention (negative = spending) and
/// the `"accountId|providerId"` id scheme, so categorization, transfers, and
/// charts treat Apple Card transactions exactly like synced ones.
enum StatementImporter {

    /// Stable, synthetic id for the single Apple Card account. Constant (not a
    /// UUID) so re-importing updates the same account instead of duplicating it.
    static let accountId = "applecard-import"
    static let accountName = "Apple Card"

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case empty
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Phinny can't read a .\(ext) file. Export your Apple Card statement as CSV, OFX, QFX, or QBO."
            case .empty:
                return "No transactions were found in that file."
            case .parseFailed(let detail):
                return "Could not read the statement: \(detail)"
            }
        }
    }

    /// Parse a statement file. `filename` is used only to pick the parser by
    /// extension (the content is what's actually trusted).
    static func parse(data: Data, filename: String) throws -> SimpleFINClient.FetchResult {
        let ext = (filename as NSString).pathExtension.lowercased()
        let text = decodeText(data)

        let result: SimpleFINClient.FetchResult
        switch ext {
        case "ofx", "qfx", "qbo":
            result = try parseOFX(text)
        case "csv":
            result = try parseCSV(text)
        case "":
            // No extension: sniff the content. OFX starts with an OFX header or
            // an "<OFX>" tag; otherwise assume CSV.
            if text.contains("<OFX>") || text.uppercased().contains("OFXHEADER") {
                result = try parseOFX(text)
            } else {
                result = try parseCSV(text)
            }
        default:
            throw ImportError.unsupportedFormat(ext)
        }

        guard !result.transactions.isEmpty else { throw ImportError.empty }
        return result
    }

    // MARK: - OFX / QFX / QBO (SGML or XML)

    /// OFX leaf elements often omit their closing tag (SGML), e.g.
    /// `<TRNAMT>-12.34`, while OFX 2.x is well-formed XML
    /// (`<TRNAMT>-12.34</TRNAMT>`). Reading each value up to the next `<` (or end
    /// of line) handles both.
    private static func parseOFX(_ text: String) throws -> SimpleFINClient.FetchResult {
        var transactions: [Transaction] = []
        for block in blocks(of: "STMTTRN", in: text) {
            guard let fitid = tagValue("FITID", in: block) else { continue }
            let amount = Double(tagValue("TRNAMT", in: block) ?? "") ?? 0
            let posted = ofxDate(tagValue("DTPOSTED", in: block)) ?? 0
            let name = tagValue("NAME", in: block) ?? ""
            let memo = tagValue("MEMO", in: block)
            transactions.append(Transaction(
                id: "\(accountId)|\(fitid)",
                providerId: fitid,
                accountId: accountId,
                posted: posted,
                amount: amount,                 // OFX TRNAMT is already debit-negative
                descriptionText: name.isEmpty ? (memo ?? "") : name,
                payee: name.isEmpty ? nil : name,
                memo: memo,
                category: nil,
                pending: false
            ))
        }

        // Statement balance, if the file carries a <LEDGERBAL>.
        var balance = 0.0
        var balanceDate: Int? = nil
        if let bal = blocks(of: "LEDGERBAL", in: text).first {
            balance = Double(tagValue("BALAMT", in: bal) ?? "") ?? 0
            balanceDate = ofxDate(tagValue("DTASOF", in: bal))
        }

        let account = Account(
            id: accountId, name: accountName, orgName: accountName,
            currency: tagValue("CURDEF", in: text) ?? "USD",
            balance: balance, availableBalance: nil, balanceDate: balanceDate)
        return SimpleFINClient.FetchResult(accounts: [account], transactions: transactions)
    }

    /// All `<TAG>...</TAG>` blocks. The opening tag is matched case-insensitively;
    /// the block runs to the matching close tag.
    private static func blocks(of tag: String, in text: String) -> [String] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result: [String] = []
        var searchStart = text.startIndex
        let upper = text.uppercased()
        while let openRange = upper.range(of: open, range: searchStart..<upper.endIndex) {
            guard let closeRange = upper.range(of: close, range: openRange.upperBound..<upper.endIndex)
            else { break }
            result.append(String(text[openRange.upperBound..<closeRange.lowerBound]))
            searchStart = closeRange.upperBound
        }
        return result
    }

    /// The value of a leaf OFX element: from after `<TAG>` up to the next `<` or
    /// end of line, trimmed.
    private static func tagValue(_ tag: String, in block: String) -> String? {
        let upper = block.uppercased()
        guard let r = upper.range(of: "<\(tag)>") else { return nil }
        let rest = block[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
        let value = rest[rest.startIndex..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// OFX dates are `YYYYMMDD` optionally followed by time / `[tz]`. We only
    /// need the day, taken as local midnight epoch seconds.
    private static func ofxDate(_ raw: String?) -> Int? {
        guard let raw, raw.count >= 8 else { return nil }
        let digits = String(raw.prefix(8))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = .current
        guard let date = fmt.date(from: digits) else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    // MARK: - CSV (Apple Card export)

    /// Apple's CSV columns: Transaction Date, Clearing Date, Description,
    /// Merchant, Category, Type, Amount (USD). Apple shows purchases as POSITIVE
    /// amounts, so we negate to match SimpleFIN's "negative = spending" rule.
    /// CSV carries no transaction id, so we derive a deterministic content hash
    /// (FNV-1a) - re-importing an overlapping month upserts instead of dupes.
    private static func parseCSV(_ text: String) throws -> SimpleFINClient.FetchResult {
        let rows = parseCSVRows(text)
        guard let header = rows.first else { throw ImportError.empty }

        func col(_ names: [String]) -> Int? {
            for (i, h) in header.enumerated() {
                let norm = h.lowercased().trimmingCharacters(in: .whitespaces)
                if names.contains(where: { norm == $0 || norm.hasPrefix($0) }) { return i }
            }
            return nil
        }
        guard let amountIdx = col(["amount (usd)", "amount"]) else {
            throw ImportError.parseFailed("CSV is missing an Amount column.")
        }
        let dateIdx = col(["transaction date", "date"])
        let descIdx = col(["description"])
        let merchantIdx = col(["merchant"])
        let categoryIdx = col(["category"])

        func field(_ row: [String], _ idx: Int?) -> String? {
            guard let idx, idx < row.count else { return nil }
            let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        var transactions: [Transaction] = []
        for row in rows.dropFirst() {
            guard amountIdx < row.count else { continue }
            let amountRaw = row[amountIdx]
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(amountRaw) else { continue }
            let amount = -parsed                                  // purchase (+) -> spending (-)
            let dateStr = field(row, dateIdx)
            let posted = csvDate(dateStr) ?? 0
            let merchant = field(row, merchantIdx)
            let desc = field(row, descIdx) ?? merchant ?? ""
            let providerId = contentHash([dateStr ?? "", amountRaw, desc, merchant ?? ""])
            transactions.append(Transaction(
                id: "\(accountId)|\(providerId)",
                providerId: providerId,
                accountId: accountId,
                posted: posted,
                amount: amount,
                descriptionText: desc,
                payee: merchant,
                memo: nil,
                category: field(row, categoryIdx),
                pending: false
            ))
        }

        // CSV has no running balance - leave it 0 and let any existing OFX/synced
        // value win on upsert is not possible, so just report 0 (the account row
        // still upserts; balance is informational for the Apple Card card).
        let account = Account(
            id: accountId, name: accountName, orgName: accountName,
            currency: "USD", balance: 0, availableBalance: nil, balanceDate: nil)
        return SimpleFINClient.FetchResult(accounts: [account], transactions: transactions)
    }

    /// Apple CSV dates are `MM/DD/YYYY`. Fall back to ISO `YYYY-MM-DD`.
    private static func csvDate(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        for format in ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yyyy"] {
            let fmt = DateFormatter()
            fmt.dateFormat = format
            fmt.timeZone = .current
            if let date = fmt.date(from: raw) { return Int(date.timeIntervalSince1970) }
        }
        return nil
    }

    /// Minimal RFC-4180 CSV: handles quoted fields, escaped quotes (""), and
    /// commas/newlines inside quotes. Returns rows of string fields.
    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: - Helpers

    /// Deterministic 64-bit FNV-1a hash, hex-encoded. Stable across runs (unlike
    /// Swift's randomized `Hasher`), so the same CSV row always yields the same
    /// id and re-imports upsert cleanly.
    private static func contentHash(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in parts.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }

    private static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
