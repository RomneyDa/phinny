// Package analytics turns raw transactions into the series the dashboard
// renders. Pure functions, no I/O (mirrors Analytics.swift).
package analytics

import (
	"sort"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// MonthlyFlow is income vs spending for one calendar month.
type MonthlyFlow struct {
	Month   int64   `json:"month"` // epoch seconds of the first day of the month
	Income  float64 `json:"income"`
	Expense float64 `json:"expense"`
	Net     float64 `json:"net"`
}

// CategorySpend is spending grouped by category/merchant.
type CategorySpend struct {
	Label  string  `json:"label"`
	Amount float64 `json:"amount"`
}

// Summary holds the headline numbers for the summary cards.
//
// TotalBalance covers liquid accounts only (credit cards carry negative
// balances, so they already net out). NetWorth additionally folds in home
// equity, which lives outside the account tables; see WithMortgageEquity.
type Summary struct {
	TotalBalance        float64 `json:"total_balance"`
	MortgageEquity      float64 `json:"mortgage_equity"`
	NetWorth            float64 `json:"net_worth"`
	CurrentMonthIncome  float64 `json:"current_month_income"`
	CurrentMonthExpense float64 `json:"current_month_expense"`
	CurrentMonthNet     float64 `json:"current_month_net"`
	TransactionCount    int     `json:"transaction_count"`
	AccountCount        int     `json:"account_count"`
}

// WithMortgageEquity folds home equity into the summary and returns the result,
// so net worth is account balances plus equity. Mortgages are not accounts, so
// the caller (the service layer, which can read them) supplies the total rather
// than this package reaching for I/O.
func (s Summary) WithMortgageEquity(equity float64) Summary {
	s.MortgageEquity = equity
	s.NetWorth = s.TotalBalance + equity
	return s
}

// NetWorthPoint is net worth at the end of one month, split into the two parts
// it is made of so a chart can stack them.
type NetWorthPoint struct {
	Month    int64   `json:"month"` // epoch seconds of the first day of the month
	Accounts float64 `json:"accounts"`
	Equity   float64 `json:"equity"`
	NetWorth float64 `json:"net_worth"`
}

// AccountRollup is the per-account breakdown behind the aggregate summary, so
// the dashboard can show where a balance actually sits instead of one total.
// The monthly figures use the same transfer-filtered set as Summary, keeping a
// rollup consistent with the headline it adds up to.
type AccountRollup struct {
	AccountID           string  `json:"account_id"`
	Name                string  `json:"name"`
	OrgName             string  `json:"org_name"`
	Currency            string  `json:"currency"`
	Balance             float64 `json:"balance"`
	CurrentMonthIncome  float64 `json:"current_month_income"`
	CurrentMonthExpense float64 `json:"current_month_expense"`
	CurrentMonthNet     float64 `json:"current_month_net"`
	TransactionCount    int     `json:"transaction_count"`
}

func startOfMonth(t time.Time) time.Time {
	y, m, _ := t.Date()
	return time.Date(y, m, 1, 0, 0, 0, 0, t.Location())
}

// MonthlyFlows returns income/expense per month for the last `months` months
// (oldest first), including empty months so the chart axis is continuous.
func MonthlyFlows(txns []model.Transaction, months int, now time.Time) []MonthlyFlow {
	if months <= 0 {
		months = 12
	}
	thisMonth := startOfMonth(now)

	buckets := make([]time.Time, 0, months)
	for offset := months - 1; offset >= 0; offset-- {
		buckets = append(buckets, thisMonth.AddDate(0, -offset, 0))
	}
	earliest := buckets[0]

	income := map[int64]float64{}
	expense := map[int64]float64{}
	for _, t := range txns {
		d := t.Date()
		if d.Before(earliest) {
			continue
		}
		key := startOfMonth(d).Unix()
		if t.Amount >= 0 {
			income[key] += t.Amount
		} else {
			expense[key] += -t.Amount
		}
	}

	out := make([]MonthlyFlow, 0, len(buckets))
	for _, b := range buckets {
		k := b.Unix()
		inc, exp := income[k], expense[k]
		out = append(out, MonthlyFlow{Month: k, Income: inc, Expense: exp, Net: inc - exp})
	}
	return out
}

// TopSpending returns the top spending groups within the last `days` days.
// Anything past topN is collapsed into "Other". `label` maps a transaction to
// its group label (e.g. effective category name).
func TopSpending(txns []model.Transaction, days, topN int, now time.Time, label func(model.Transaction) string) []CategorySpend {
	if days <= 0 {
		days = 30
	}
	if topN <= 0 {
		topN = 7
	}
	cutoff := now.AddDate(0, 0, -days)
	totals := map[string]float64{}
	for _, t := range txns {
		if !t.IsExpense() || t.Date().Before(cutoff) {
			continue
		}
		totals[label(t)] += -t.Amount
	}
	sorted := make([]CategorySpend, 0, len(totals))
	for k, v := range totals {
		sorted = append(sorted, CategorySpend{Label: k, Amount: v})
	}
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Amount != sorted[j].Amount {
			return sorted[i].Amount > sorted[j].Amount
		}
		return sorted[i].Label < sorted[j].Label
	})
	if len(sorted) <= topN {
		return sorted
	}
	top := append([]CategorySpend(nil), sorted[:topN]...)
	other := 0.0
	for _, s := range sorted[topN:] {
		other += s.Amount
	}
	return append(top, CategorySpend{Label: "Other", Amount: other})
}

// SummaryOf computes the headline numbers.
func SummaryOf(accounts []model.Account, txns []model.Transaction, now time.Time) Summary {
	s := Summary{AccountCount: len(accounts), TransactionCount: len(txns)}
	for _, a := range accounts {
		s.TotalBalance += a.Balance
	}
	monthStart := startOfMonth(now)
	for _, t := range txns {
		if t.Date().Before(monthStart) {
			continue
		}
		if t.Amount >= 0 {
			s.CurrentMonthIncome += t.Amount
		} else {
			s.CurrentMonthExpense += -t.Amount
		}
	}
	s.CurrentMonthNet = s.CurrentMonthIncome - s.CurrentMonthExpense
	// With no mortgages, net worth is just the balances. Callers that own
	// mortgages layer equity on with WithMortgageEquity.
	s.NetWorth = s.TotalBalance
	return s
}

// NetWorthSeries reconstructs net worth at the end of each of the last `months`
// months (oldest first, the last point being today).
//
// Balances are walked backwards from today: the balance at a past date is the
// current balance minus everything that has posted since. That makes the series
// exact for cash and card accounts, where transactions are the only thing that
// moves a balance. It cannot see market movement in a brokerage or retirement
// account, which changes a balance with no transaction behind it, so history
// for those accounts reflects contributions only.
//
// Pass every visible transaction, not the transfer-filtered set: a transfer
// moves money between two tracked accounts and nets to zero across them, while
// dropping one leg would skew the reconstruction.
//
// equityAt supplies home equity as of a date, which lives outside the account
// tables; pass nil when there are no mortgages.
func NetWorthSeries(accounts []model.Account, txns []model.Transaction, months int, now time.Time, equityAt func(time.Time) float64) []NetWorthPoint {
	if months <= 0 {
		months = 12
	}
	current := 0.0
	for _, a := range accounts {
		current += a.Balance
	}

	// Transactions only go back as far as the provider returned them. Walking
	// past that would draw a flat line that looks like a balance which did not
	// move, when really there is nothing to reconstruct from, so the series
	// starts at the first month there is data for.
	earliest := int64(0)
	for _, t := range txns {
		if earliest == 0 || t.Posted < earliest {
			earliest = t.Posted
		}
	}

	thisMonth := startOfMonth(now)
	out := make([]NetWorthPoint, 0, months)
	for offset := months - 1; offset >= 0; offset-- {
		start := thisMonth.AddDate(0, -offset, 0)
		// Measure at the end of the month, except for the current one, which
		// is measured as of now so the last point matches the summary card.
		asOf := start.AddDate(0, 1, 0)
		if offset == 0 {
			asOf = now
		}
		if earliest != 0 && asOf.Unix() < earliest {
			continue
		}

		balance := current
		if offset > 0 {
			for _, t := range txns {
				if t.Date().After(asOf) {
					balance -= t.Amount
				}
			}
		}
		// The current month is the balances as they stand, so the last point
		// always equals the summary card. Undoing a transaction dated in the
		// future (banks do post them) would otherwise pull the two apart.
		equity := 0.0
		if equityAt != nil {
			equity = equityAt(asOf)
		}
		out = append(out, NetWorthPoint{
			Month:    start.Unix(),
			Accounts: balance,
			Equity:   equity,
			NetWorth: balance + equity,
		})
	}
	return out
}

// AccountRollups breaks the summary down per account, largest balance first, so
// the dashboard can list where the money sits. Pass the same transfer-filtered
// transactions given to SummaryOf so the parts match the whole.
func AccountRollups(accounts []model.Account, txns []model.Transaction, now time.Time) []AccountRollup {
	byAccount := make(map[string]*AccountRollup, len(accounts))
	out := make([]AccountRollup, 0, len(accounts))
	for _, a := range accounts {
		out = append(out, AccountRollup{
			AccountID: a.ID,
			Name:      a.Name,
			OrgName:   a.OrgName,
			Currency:  a.Currency,
			Balance:   a.Balance,
		})
	}
	for i := range out {
		byAccount[out[i].AccountID] = &out[i]
	}

	monthStart := startOfMonth(now)
	for _, t := range txns {
		r, ok := byAccount[t.AccountID]
		if !ok {
			// A transaction on a hidden account when the caller passed only
			// visible ones. Skip it rather than inventing a rollup.
			continue
		}
		r.TransactionCount++
		if t.Date().Before(monthStart) {
			continue
		}
		if t.Amount >= 0 {
			r.CurrentMonthIncome += t.Amount
		} else {
			r.CurrentMonthExpense += -t.Amount
		}
	}
	for i := range out {
		out[i].CurrentMonthNet = out[i].CurrentMonthIncome - out[i].CurrentMonthExpense
	}

	sort.SliceStable(out, func(i, j int) bool { return out[i].Balance > out[j].Balance })
	return out
}
