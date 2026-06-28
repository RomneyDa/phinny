import Foundation

/// Pure amortization math. No I/O - give it a mortgage plus its adjustments and
/// it returns the month-by-month schedule and a headline summary. This is the
/// reason you don't have to log every payment: the whole timeline is computed.
enum MortgageEngine {

    /// One month of the amortization schedule.
    struct Point: Identifiable {
        let date: Date
        let balance: Double
        let payment: Double
        let interest: Double
        let principal: Double
        let extraPrincipal: Double
        let cumulativeInterest: Double
        let cumulativePrincipal: Double
        let homeValue: Double
        var id: Date { date }
        var equity: Double { homeValue - balance }
    }

    /// Headline numbers as of a given date.
    struct Summary {
        var currentBalance: Double
        var monthlyPayment: Double
        var homeValue: Double
        var equity: Double
        var interestPaidToDate: Double
        var principalPaidToDate: Double
        var originalPrincipal: Double
        var purchasePrice: Double
        var totalInterestOverLife: Double
        var payoffDate: Date?
        var nextPaymentDate: Date?
        var percentPaidOff: Double
    }

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// Standard fixed-rate monthly payment for `principal` over `months` at
    /// monthly rate `r`.
    static func payment(principal: Double, monthlyRate r: Double, months: Int) -> Double {
        guard months > 0 else { return principal }
        guard r > 0 else { return principal / Double(months) }
        let factor = pow(1 + r, Double(months))
        return principal * r * factor / (factor - 1)
    }

    /// Full schedule from the start date until the loan is paid off (or the term
    /// ends). Applies rate changes (re-amortizing the remaining balance over the
    /// remaining term) and extra principal payments (which shorten the loan).
    static func schedule(
        for m: Mortgage,
        rateChanges: [MortgageRateChange] = [],
        extraPayments: [MortgageManualTxn] = [],
        valuations: [HomeValuation] = []
    ) -> [Point] {
        let cal = calendar
        let n = max(1, m.termMonths)
        var balance = m.principal
        var monthlyRate = m.monthlyRate
        var monthlyPayment = payment(principal: balance, monthlyRate: monthlyRate, months: n)

        let sortedRates = rateChanges.sorted { $0.effectiveDate < $1.effectiveDate }
        let valueLookup = HomeValueLookup(mortgage: m, valuations: valuations)

        var points: [Point] = []
        var cumInterest = 0.0
        var cumPrincipal = 0.0

        for i in 0..<n {
            guard let monthStart = cal.date(byAdding: .month, value: i, to: m.start) else { break }
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

            // Apply a rate change that takes effect this month: re-amortize the
            // remaining balance over the remaining term.
            if let change = sortedRates.last(where: { $0.date <= monthStart }),
               abs(change.monthlyRate - monthlyRate) > 1e-12 {
                monthlyRate = change.monthlyRate
                monthlyPayment = payment(principal: balance, monthlyRate: monthlyRate, months: n - i)
            }

            let interest = balance * monthlyRate
            var principalPart = min(monthlyPayment - interest, balance)
            if principalPart < 0 { principalPart = 0 }
            balance -= principalPart

            // Extra principal payments recorded within this month.
            let extra = extraPayments
                .filter { $0.asDate >= monthStart && $0.asDate < monthEnd }
                .reduce(0) { $0 + $1.amount }
            let appliedExtra = min(extra, balance)
            balance -= appliedExtra

            cumInterest += interest
            cumPrincipal += principalPart + appliedExtra

            points.append(Point(
                date: monthStart,
                balance: balance,
                payment: monthlyPayment,
                interest: interest,
                principal: principalPart,
                extraPrincipal: appliedExtra,
                cumulativeInterest: cumInterest,
                cumulativePrincipal: cumPrincipal,
                homeValue: valueLookup.value(at: monthStart)
            ))

            if balance <= 0.01 { break }
        }
        return points
    }

    static func summary(
        for m: Mortgage,
        rateChanges: [MortgageRateChange] = [],
        extraPayments: [MortgageManualTxn] = [],
        valuations: [HomeValuation] = [],
        asOf now: Date = Date()
    ) -> Summary {
        let points = schedule(for: m, rateChanges: rateChanges,
                              extraPayments: extraPayments, valuations: valuations)
        let valueLookup = HomeValueLookup(mortgage: m, valuations: valuations)
        let homeValueNow = valueLookup.value(at: now)

        let past = points.filter { $0.date <= now }
        let current = past.last
        let next = points.first { $0.date > now }
        let balance = current?.balance ?? m.principal
        let interestPaid = current?.cumulativeInterest ?? 0
        let principalPaid = m.principal - balance
        let totalInterest = points.last?.cumulativeInterest ?? 0
        let monthlyPayment = (next ?? current ?? points.first)?.payment
            ?? payment(principal: m.principal, monthlyRate: m.monthlyRate, months: m.termMonths)

        return Summary(
            currentBalance: max(0, balance),
            monthlyPayment: monthlyPayment,
            homeValue: homeValueNow,
            equity: homeValueNow - max(0, balance),
            interestPaidToDate: interestPaid,
            principalPaidToDate: max(0, principalPaid),
            originalPrincipal: m.principal,
            purchasePrice: m.purchasePrice,
            totalInterestOverLife: totalInterest,
            payoffDate: points.last?.date,
            nextPaymentDate: next?.date,
            percentPaidOff: m.principal > 0 ? max(0, principalPaid) / m.principal : 0
        )
    }
}

/// Carries the most-recent home valuation forward (step function), seeded with
/// the purchase price at the start date.
private struct HomeValueLookup {
    private let sorted: [(date: Date, value: Double)]

    init(mortgage m: Mortgage, valuations: [HomeValuation]) {
        var points: [(Date, Double)] = [(m.start, m.purchasePrice)]
        points += valuations.map { ($0.asDate, $0.value) }
        sorted = points.sorted { $0.0 < $1.0 }.map { (date: $0.0, value: $0.1) }
    }

    func value(at date: Date) -> Double {
        let applicable = sorted.last { $0.date <= date }
        return applicable?.value ?? sorted.first?.value ?? 0
    }
}
