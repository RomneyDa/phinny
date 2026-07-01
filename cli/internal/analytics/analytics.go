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
type Summary struct {
	TotalBalance        float64 `json:"total_balance"`
	CurrentMonthIncome  float64 `json:"current_month_income"`
	CurrentMonthExpense float64 `json:"current_month_expense"`
	CurrentMonthNet     float64 `json:"current_month_net"`
	TransactionCount    int     `json:"transaction_count"`
	AccountCount        int     `json:"account_count"`
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
	return s
}
