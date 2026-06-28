import Foundation

/// Matching synced expenses to a mortgage's recurring payment, and detecting
/// likely payments historically. Pure functions over the transaction list.
enum MortgageDetection {

    /// Lowercased, punctuation-stripped label for fuzzy payee comparison.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// All transactions that match this mortgage's payment signature. Prefers a
    /// payee match; falls back to amount proximity when no payee is set.
    static func matches(_ transactions: [Transaction], for m: Mortgage) -> [Transaction] {
        if let payee = m.paymentPayee, !payee.isEmpty {
            let sig = normalize(payee)
            guard !sig.isEmpty else { return [] }
            return transactions.filter { txn in
                guard txn.isExpense else { return false }
                let label = normalize(txn.payee ?? txn.descriptionText)
                return !label.isEmpty && (label.contains(sig) || sig.contains(label))
            }
        }
        if let amount = m.paymentAmount {
            return transactions.filter { $0.isExpense && amountsMatch(abs($0.amount), abs(amount)) }
        }
        return []
    }

    static func amountsMatch(_ a: Double, _ b: Double) -> Bool {
        guard b > 0 else { return false }
        return abs(a - b) <= max(25, b * 0.02)   // within $25 or 2%
    }

    /// A suggested recurring payment found in the transaction history.
    struct Suggestion {
        let payee: String
        let amount: Double      // negative (expense)
        let count: Int
        let lastDate: Date?
    }

    /// Look for a recurring expense near `monthlyPayment` (e.g. the auto-pay to a
    /// lender). Groups expenses by payee, scores by how close the typical amount
    /// is to the expected payment and how often it recurs.
    static func detect(in transactions: [Transaction], expectedPayment: Double) -> Suggestion? {
        let expenses = transactions.filter { $0.isExpense }
        var groups: [String: [Transaction]] = [:]
        for txn in expenses {
            let key = normalize(txn.payee ?? txn.descriptionText)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(txn)
        }

        var best: Suggestion?
        var bestScore = Double.greatestFiniteMagnitude
        for (_, txns) in groups where txns.count >= 2 {
            let amounts = txns.map { abs($0.amount) }.sorted()
            let median = amounts[amounts.count / 2]
            // Only consider groups whose typical amount is near the expected one.
            guard expectedPayment <= 0 || abs(median - expectedPayment) <= expectedPayment * 0.25 else { continue }
            // Lower is better: closeness to expected payment, favoring more recurrences.
            let closeness = expectedPayment > 0 ? abs(median - expectedPayment) / expectedPayment : 0
            let score = closeness - Double(txns.count) * 0.01
            if score < bestScore {
                bestScore = score
                let label = txns.first?.payee ?? txns.first?.descriptionText ?? ""
                best = Suggestion(
                    payee: label,
                    amount: -median,
                    count: txns.count,
                    lastDate: txns.map { $0.date }.max()
                )
            }
        }
        return best
    }
}
