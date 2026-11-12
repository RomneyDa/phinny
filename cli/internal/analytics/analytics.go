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
