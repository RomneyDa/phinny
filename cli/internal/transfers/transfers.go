// Package transfers spots money moved between your own accounts (not real
// income or spending). Pure, no I/O (mirrors TransferDetection.swift).
package transfers

import (
	"sort"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// DefaultWindowDays is how far apart the two legs of a transfer may post.
const DefaultWindowDays = 3

// epsilon: amounts within half a cent are treated as offsetting.
const epsilon = 0.005

// Detect returns the set of transaction ids that participate in a detected
// transfer pair: an outflow in one account offset by an inflow in a different
// account within `windowDays`. Each transaction is matched at most once; the
// closest inflow by date wins.
func Detect(txns []model.Transaction, windowDays int) map[string]bool {
	if windowDays <= 0 {
		windowDays = DefaultWindowDays
	}
	window := int64(windowDays) * 86400

	var outflows, inflows []model.Transaction
	for _, t := range txns {
		if t.IsExpense() {
			outflows = append(outflows, t)
		} else if t.IsIncome() {
			inflows = append(inflows, t)
		}
	}
	sort.Slice(outflows, func(i, j int) bool { return outflows[i].Posted < outflows[j].Posted })

	usedInflow := map[string]bool{}
	matched := map[string]bool{}

	for _, out := range outflows {
		var best *model.Transaction
		bestGap := int64(1) << 62
		for i := range inflows {
			inc := inflows[i]
			if usedInflow[inc.ID] {
				continue
			}
			if inc.AccountID == out.AccountID {
				continue
			}
			if abs(inc.Amount+out.Amount) >= epsilon {
				continue
			}
			gap := absI(inc.Posted - out.Posted)
			if gap > window {
				continue
			}
			if gap < bestGap {
				b := inc
				best = &b
				bestGap = gap
			}
		}
		if best == nil {
			continue
		}
		usedInflow[best.ID] = true
		matched[out.ID] = true
		matched[best.ID] = true
	}
	return matched
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
func absI(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}
