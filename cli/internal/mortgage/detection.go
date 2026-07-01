package mortgage

import (
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// Normalize lowercases and strips punctuation for fuzzy payee comparison
// (mirrors MortgageDetection.normalize).
func Normalize(s string) string {
	var b strings.Builder
	prevSpace := true // collapse leading + repeated separators
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			prevSpace = false
		} else if !prevSpace {
			b.WriteByte(' ')
			prevSpace = true
		}
	}
	return strings.TrimSpace(b.String())
}

// Matches returns every transaction matching a mortgage's payment signature:
// same account AND same title (payee/description). Amount is ignored.
// PaymentAccountID nil means the account constraint is skipped.
func Matches(txns []model.Transaction, m model.Mortgage) []model.Transaction {
	if m.PaymentPayee == nil || *m.PaymentPayee == "" {
		return nil
	}
	sig := Normalize(*m.PaymentPayee)
	if sig == "" {
		return nil
	}
	var out []model.Transaction
	for _, t := range txns {
		if !t.IsExpense() {
			continue
		}
		if m.PaymentAccountID != nil && t.AccountID != *m.PaymentAccountID {
			continue
		}
		label := Normalize(t.PayeeOrDescription())
		if label != "" && (strings.Contains(label, sig) || strings.Contains(sig, label)) {
			out = append(out, t)
		}
	}
	return out
}

// Suggestion is a recurring payment found in the transaction history.
type Suggestion struct {
	Payee    string   `json:"payee"`
	Amount   float64  `json:"amount"` // negative (expense)
	Count    int      `json:"count"`
	LastDate *int64   `json:"last_date,omitempty"`
}

// Detect looks for a recurring expense near `expectedPayment`, scoring by how
// close the typical amount is and how often it recurs.
func Detect(txns []model.Transaction, expectedPayment float64) *Suggestion {
	groups := map[string][]model.Transaction{}
	for _, t := range txns {
		if !t.IsExpense() {
			continue
		}
		key := Normalize(t.PayeeOrDescription())
		if key == "" {
			continue
		}
		groups[key] = append(groups[key], t)
	}

	// Deterministic iteration order so ties resolve consistently.
	keys := make([]string, 0, len(groups))
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var best *Suggestion
	bestScore := 1.0e308
	for _, k := range keys {
		txs := groups[k]
		if len(txs) < 2 {
			continue
		}
		amounts := make([]float64, len(txs))
		for i, t := range txs {
			amounts[i] = absF(t.Amount)
		}
		sort.Float64s(amounts)
		median := amounts[len(amounts)/2]
		if expectedPayment > 0 && absF(median-expectedPayment) > expectedPayment*0.25 {
			continue
		}
		closeness := 0.0
		if expectedPayment > 0 {
			closeness = absF(median-expectedPayment) / expectedPayment
		}
		score := closeness - float64(len(txs))*0.01
		if score < bestScore {
			bestScore = score
			label := txs[0].PayeeOrDescription()
			var last *int64
			var maxT time.Time
			for _, t := range txs {
				if t.Date().After(maxT) {
					maxT = t.Date()
				}
			}
			if !maxT.IsZero() {
				u := maxT.Unix()
				last = &u
			}
			best = &Suggestion{Payee: label, Amount: -median, Count: len(txs), LastDate: last}
		}
	}
	return best
}

func absF(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
