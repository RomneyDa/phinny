import Foundation

/// Payee normalization (used by the app to group "similar" transactions for the
/// detail-sheet preview) and the decoded payment `Suggestion` the phinny engine
/// returns. The actual detection/matching now runs in the Go engine; this Swift
/// `normalize` mirrors it so the local "applies to N transactions" preview agrees
/// with what the daemon will tag.
enum MortgageDetection {

    /// Lowercased, punctuation-stripped label for fuzzy payee comparison.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A suggested recurring payment found in the transaction history (decoded
    /// from the daemon's `mortgages.detectPayment`).
    struct Suggestion: Decodable {
        let payee: String
        let amount: Double      // negative (expense)
        let count: Int
        let lastDate: Date?

        enum CodingKeys: String, CodingKey {
            case payee, amount, count
            case lastDate = "last_date"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            payee = try c.decode(String.self, forKey: .payee)
            amount = try c.decode(Double.self, forKey: .amount)
            count = try c.decode(Int.self, forKey: .count)
            if let e = try c.decodeIfPresent(Int.self, forKey: .lastDate) {
                lastDate = Date(timeIntervalSince1970: TimeInterval(e))
            } else {
                lastDate = nil
            }
        }
    }
}
