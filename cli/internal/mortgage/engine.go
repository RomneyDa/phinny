// Package mortgage holds the pure amortization math and payment detection
// (mirrors MortgageEngine.swift + MortgageDetection.swift). No I/O: give it a
// mortgage plus its adjustments and it returns the schedule and a summary.
package mortgage

import (
	"math"
	"sort"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// Point is one month of the amortization schedule.
type Point struct {
	Date                int64   `json:"date"` // epoch seconds, first of the month
	Balance             float64 `json:"balance"`
	Payment             float64 `json:"payment"`
	Interest            float64 `json:"interest"`
	Principal           float64 `json:"principal"`
	ExtraPrincipal      float64 `json:"extra_principal"`
	CumulativeInterest  float64 `json:"cumulative_interest"`
	CumulativePrincipal float64 `json:"cumulative_principal"`
	HomeValue           float64 `json:"home_value"`
	Equity              float64 `json:"equity"`
}

// Summary holds the headline numbers as of a given date.
type Summary struct {
	CurrentBalance       float64 `json:"current_balance"`
	MonthlyPayment       float64 `json:"monthly_payment"`
	HomeValue            float64 `json:"home_value"`
	Equity               float64 `json:"equity"`
	InterestPaidToDate   float64 `json:"interest_paid_to_date"`
	PrincipalPaidToDate  float64 `json:"principal_paid_to_date"`
	OriginalPrincipal    float64 `json:"original_principal"`
	PurchasePrice        float64 `json:"purchase_price"`
	TotalInterestOverLife float64 `json:"total_interest_over_life"`
	PayoffDate           *int64  `json:"payoff_date,omitempty"`
	NextPaymentDate      *int64  `json:"next_payment_date,omitempty"`
	PercentPaidOff       float64 `json:"percent_paid_off"`
}

// Payment is the standard fixed-rate monthly payment for `principal` over
// `months` at monthly rate r.
func Payment(principal, r float64, months int) float64 {
	if months <= 0 {
		return principal
	}
	if r <= 0 {
		return principal / float64(months)
	}
	factor := math.Pow(1+r, float64(months))
	return principal * r * factor / (factor - 1)
}

type valuePoint struct {
	date  time.Time
	value float64
}

// homeValueLookup carries the most recent valuation forward (step function),
// seeded with the purchase price at the start date.
type homeValueLookup struct {
	sorted []valuePoint
}

func newHomeValueLookup(m model.Mortgage, valuations []model.HomeValuation) homeValueLookup {
	pts := []valuePoint{{m.Start(), m.PurchasePrice()}}
	for _, v := range valuations {
		pts = append(pts, valuePoint{v.AsDate(), v.Value})
	}
	sort.Slice(pts, func(i, j int) bool { return pts[i].date.Before(pts[j].date) })
	return homeValueLookup{sorted: pts}
}

func (h homeValueLookup) value(at time.Time) float64 {
	var applicable *valuePoint
	for i := range h.sorted {
		if !h.sorted[i].date.After(at) {
			applicable = &h.sorted[i]
		}
	}
	if applicable != nil {
		return applicable.value
	}
	if len(h.sorted) > 0 {
		return h.sorted[0].value
	}
	return 0
}

// Schedule computes the full month-by-month schedule until payoff (or term end),
// applying rate changes (re-amortizing over the remaining term) and extra
// principal payments (which shorten the loan).
func Schedule(m model.Mortgage, rateChanges []model.MortgageRateChange, extras []model.MortgageManualTxn, valuations []model.HomeValuation) []Point {
	n := m.TermMonths
	if n < 1 {
		n = 1
	}
	balance := m.Principal
	monthlyRate := m.MonthlyRate()
	monthlyPayment := Payment(balance, monthlyRate, n)

	sortedRates := append([]model.MortgageRateChange(nil), rateChanges...)
	sort.Slice(sortedRates, func(i, j int) bool { return sortedRates[i].EffectiveDate < sortedRates[j].EffectiveDate })
	valueLookup := newHomeValueLookup(m, valuations)

	var points []Point
	cumInterest, cumPrincipal := 0.0, 0.0
	start := m.Start()

	for i := 0; i < n; i++ {
		monthStart := start.AddDate(0, i, 0)
		monthEnd := monthStart.AddDate(0, 1, 0)

		// Apply a rate change effective this month.
		var change *model.MortgageRateChange
		for j := range sortedRates {
			if !sortedRates[j].Date().After(monthStart) {
				change = &sortedRates[j]
			}
		}
		if change != nil && math.Abs(change.MonthlyRate()-monthlyRate) > 1e-12 {
			monthlyRate = change.MonthlyRate()
			monthlyPayment = Payment(balance, monthlyRate, n-i)
		}

		interest := balance * monthlyRate
		principalPart := monthlyPayment - interest
		if principalPart > balance {
			principalPart = balance
		}
		if principalPart < 0 {
			principalPart = 0
		}
		balance -= principalPart

		extra := 0.0
		for _, e := range extras {
			d := e.AsDate()
			if !d.Before(monthStart) && d.Before(monthEnd) {
				extra += e.Amount
			}
		}
		appliedExtra := extra
		if appliedExtra > balance {
			appliedExtra = balance
		}
		balance -= appliedExtra

		cumInterest += interest
		cumPrincipal += principalPart + appliedExtra

		hv := valueLookup.value(monthStart)
		points = append(points, Point{
			Date:                monthStart.Unix(),
			Balance:             balance,
			Payment:             monthlyPayment,
			Interest:            interest,
			Principal:           principalPart,
			ExtraPrincipal:      appliedExtra,
			CumulativeInterest:  cumInterest,
			CumulativePrincipal: cumPrincipal,
			HomeValue:           hv,
			Equity:              hv - balance,
		})

		if balance <= 0.01 {
			break
		}
	}
	return points
}

// SummaryOf computes the headline numbers as of `now`.
func SummaryOf(m model.Mortgage, rateChanges []model.MortgageRateChange, extras []model.MortgageManualTxn, valuations []model.HomeValuation, now time.Time) Summary {
	points := Schedule(m, rateChanges, extras, valuations)
	valueLookup := newHomeValueLookup(m, valuations)
	homeValueNow := valueLookup.value(now)

	var current *Point
	var next *Point
	for i := range points {
		if points[i].Date <= now.Unix() {
			current = &points[i]
		} else if next == nil {
			next = &points[i]
		}
	}

	balance := m.Principal
	interestPaid := 0.0
	if current != nil {
		balance = current.Balance
		interestPaid = current.CumulativeInterest
	}
	principalPaid := m.Principal - balance
	if principalPaid < 0 {
		principalPaid = 0
	}
	totalInterest := 0.0
	if len(points) > 0 {
		totalInterest = points[len(points)-1].CumulativeInterest
	}

	monthlyPayment := 0.0
	switch {
	case next != nil:
		monthlyPayment = next.Payment
	case current != nil:
		monthlyPayment = current.Payment
	case len(points) > 0:
		monthlyPayment = points[0].Payment
	default:
		monthlyPayment = Payment(m.Principal, m.MonthlyRate(), m.TermMonths)
	}

	if balance < 0 {
		balance = 0
	}
	s := Summary{
		CurrentBalance:        balance,
		MonthlyPayment:        monthlyPayment,
		HomeValue:             homeValueNow,
		Equity:                homeValueNow - balance,
		InterestPaidToDate:    interestPaid,
		PrincipalPaidToDate:   principalPaid,
		OriginalPrincipal:     m.Principal,
		PurchasePrice:         m.PurchasePrice(),
		TotalInterestOverLife: totalInterest,
	}
	if len(points) > 0 {
		d := points[len(points)-1].Date
		s.PayoffDate = &d
	}
	if next != nil {
		s.NextPaymentDate = &next.Date
	}
	if m.Principal > 0 {
		s.PercentPaidOff = principalPaid / m.Principal
	}
	return s
}
