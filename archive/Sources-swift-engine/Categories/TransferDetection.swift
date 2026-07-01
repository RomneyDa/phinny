import Foundation

/// Pure logic that spots transfers: money moved between your own accounts rather
/// than real income or spending. No I/O, so it is trivial to reason about and
/// test (mirrors `Analytics` and `MortgageDetection`).
///
/// Heuristic: an outflow in one account and an inflow in a *different* account
/// with exactly offsetting amounts, posted within a few days of each other, is
/// almost always a transfer. The caller turns the matched ids into auto links to
/// the Transfer category (which the user can override).
enum TransferDetection {
    /// How far apart the two legs of a transfer may post (days).
    static let defaultWindowDays = 3

    /// Amounts within half a cent are treated as offsetting (guards against
    /// floating-point noise without matching genuinely different amounts).
    private static let epsilon = 0.005

    /// Returns the set of transaction ids that participate in a detected transfer
    /// pair. Each transaction is matched at most once; when several inflows are
    /// eligible the closest by date wins.
    static func detect(in transactions: [Transaction], windowDays: Int = defaultWindowDays) -> Set<String> {
        let window = windowDays * 86_400
        let outflows = transactions.filter { $0.isExpense }.sorted { $0.posted < $1.posted }
        let inflows = transactions.filter { $0.isIncome }

        var usedInflow = Set<String>()
        var matched = Set<String>()

        for out in outflows {
            var best: Transaction?
            var bestGap = Int.max
            for inc in inflows {
                if usedInflow.contains(inc.id) { continue }
                if inc.accountId == out.accountId { continue }
                if abs(inc.amount + out.amount) >= epsilon { continue }
                let gap = abs(inc.posted - out.posted)
                if gap > window { continue }
                if gap < bestGap { best = inc; bestGap = gap }
            }
            guard let match = best else { continue }
            usedInflow.insert(match.id)
            matched.insert(out.id)
            matched.insert(match.id)
        }
        return matched
    }
}
