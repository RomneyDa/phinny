// Package model holds Phinny's pure domain types: the records stored in SQLite
// and the small amount of derived logic that travels with them. It has no
// dependency on the database, network, or any I/O, so every other package
// (store, analytics, importer, mortgage, ...) can share these types freely.
//
// Money follows the SimpleFIN sign convention: negative = spending, positive =
// income. Dates are epoch seconds (matching SimpleFIN and the on-disk schema).
package model

import (
	"strings"
	"time"
)

// Stable, hard-coded ids that several packages reference.
const (
	// TransferCategoryID is the permanent Transfer category (seeded by
	// migration v6). It is never deletable.
	TransferCategoryID = "transfer"
	// StatementAccountID is the single synthetic account every Apple Card
	// import lands in. Constant so re-imports update the same account.
	StatementAccountID   = "applecard-import"
	StatementAccountName = "Apple Card"
)

// Account mirrors a SimpleFIN account row.
type Account struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	OrgName          string   `json:"org_name"`
	Currency         string   `json:"currency"`
	Balance          float64  `json:"balance"`
	AvailableBalance *float64 `json:"available_balance,omitempty"`
	BalanceDate      *int64   `json:"balance_date,omitempty"`
	// Hidden accounts are excluded from dashboard totals/charts. Set in the
	// app; preserved across syncs.
	Hidden bool `json:"hidden"`
}

// Transaction mirrors a SimpleFIN transaction row.
type Transaction struct {
	// ID is the globally-unique key "accountId|providerId".
	ID          string  `json:"id"`
	ProviderID  string  `json:"provider_id"`
	AccountID   string  `json:"account_id"`
	Posted      int64   `json:"posted"`
	Amount      float64 `json:"amount"`
	Description string  `json:"description"`
	Payee       *string `json:"payee,omitempty"`
	Memo        *string `json:"memo,omitempty"`
	Category    *string `json:"category,omitempty"`
	Pending     bool    `json:"pending"`
}

func (t Transaction) IsIncome() bool  { return t.Amount > 0 }
func (t Transaction) IsExpense() bool { return t.Amount < 0 }
func (t Transaction) Date() time.Time { return time.Unix(t.Posted, 0) }

// GroupLabel is the best human label for grouping/charts: category, else payee,
// else a trimmed description, else "Uncategorized".
func (t Transaction) GroupLabel() string {
	if t.Category != nil {
		if c := strings.TrimSpace(*t.Category); c != "" {
			return c
		}
	}
	if t.Payee != nil {
		if p := strings.TrimSpace(*t.Payee); p != "" {
			return p
		}
	}
	d := strings.TrimSpace(t.Description)
	if d == "" {
		return "Uncategorized"
	}
	return d
}

// PayeeOrDescription is the payee when present, else the description. Used by
// transfer/mortgage normalization.
func (t Transaction) PayeeOrDescription() string {
	if t.Payee != nil && *t.Payee != "" {
		return *t.Payee
	}
	return t.Description
}

// Mortgage and its adjustments. These tables are never touched by a sync.
type Mortgage struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Address          *string  `json:"address,omitempty"`
	ZillowURL        *string  `json:"zillow_url,omitempty"`
	Principal        float64  `json:"principal"`
	DownKind         string   `json:"down_kind"` // "percent" or "amount"
	DownValue        float64  `json:"down_value"`
	AnnualRate       float64  `json:"annual_rate"` // percent, e.g. 6.5
	TermMonths       int      `json:"term_months"`
	StartDate        int64    `json:"start_date"`
	PaymentPayee     *string  `json:"payment_payee,omitempty"`
	PaymentAmount    *float64 `json:"payment_amount,omitempty"`
	PaymentAccountID *string  `json:"payment_account_id,omitempty"`
	CreatedAt        int64    `json:"created_at"`
}

func (m Mortgage) Start() time.Time    { return time.Unix(m.StartDate, 0) }
func (m Mortgage) MonthlyRate() float64 { return m.AnnualRate / 100 / 12 }

// PurchasePrice is the original home price = loan + down payment.
func (m Mortgage) PurchasePrice() float64 {
	if m.DownKind == "percent" {
		p := m.DownValue / 100
		if p < 0 {
			p = 0
		}
		if p > 0.95 {
			p = 0.95
		}
		if p >= 1 {
			return m.Principal
		}
		return m.Principal / (1 - p)
	}
	return m.Principal + m.DownValue
}

// DownAmount is the down payment in dollars.
func (m Mortgage) DownAmount() float64 {
	if m.DownKind == "percent" {
		d := m.PurchasePrice() - m.Principal
		if d < 0 {
			return 0
		}
		return d
	}
	return m.DownValue
}

type MortgageRateChange struct {
	ID            string  `json:"id"`
	MortgageID    string  `json:"mortgage_id"`
	EffectiveDate int64   `json:"effective_date"`
	AnnualRate    float64 `json:"annual_rate"`
}

func (r MortgageRateChange) MonthlyRate() float64 { return r.AnnualRate / 100 / 12 }
func (r MortgageRateChange) Date() time.Time      { return time.Unix(r.EffectiveDate, 0) }

type HomeValuation struct {
	ID         string  `json:"id"`
	MortgageID string  `json:"mortgage_id"`
	Date       int64   `json:"date"`
	Value      float64 `json:"value"`
	Source     *string `json:"source,omitempty"` // nil/"manual" hand-entered, "zillow" automated
}

func (v HomeValuation) AsDate() time.Time { return time.Unix(v.Date, 0) }
func (v HomeValuation) IsAutomated() bool { return v.Source != nil && *v.Source != "manual" }

type MortgageManualTxn struct {
	ID         string  `json:"id"`
	MortgageID string  `json:"mortgage_id"`
	Date       int64   `json:"date"`
	Amount     float64 `json:"amount"` // positive dollars applied to principal
	Note       *string `json:"note,omitempty"`
}

func (t MortgageManualTxn) AsDate() time.Time { return time.Unix(t.Date, 0) }

type MortgagePaymentLink struct {
	TransactionID string `json:"transaction_id"`
	MortgageID    string `json:"mortgage_id"`
}

// SpendCategory is a global spending category (user- or future-AI-created).
type SpendCategory struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	ColorHex   string `json:"color_hex"`
	CreatedAt  int64  `json:"created_at"`
	IsTransfer bool   `json:"is_transfer"`
}

func (c SpendCategory) IsPermanent() bool { return c.ID == TransferCategoryID }

// ExpenseCategory links one transaction to one category, with an optional
// effective window. See conflict rules in the orchestration layer.
type ExpenseCategory struct {
	ID            string `json:"id"`
	TransactionID string `json:"transaction_id"`
	CategoryID    string `json:"category_id"`
	StartDate     *int64 `json:"start_date,omitempty"`
	EndDate       *int64 `json:"end_date,omitempty"`
	IsAuto        bool   `json:"is_auto"`
	CreatedAt     int64  `json:"created_at"`
}

func (e ExpenseCategory) HasWindow() bool { return e.StartDate != nil || e.EndDate != nil }

// Applies reports whether this link applies to a transaction posted at `posted`.
func (e ExpenseCategory) Applies(posted int64) bool {
	if e.StartDate != nil && posted < *e.StartDate {
		return false
	}
	if e.EndDate != nil && posted > *e.EndDate {
		return false
	}
	return true
}

// WindowsOverlap reports whether two effective windows overlap. nil bounds are
// open (-inf / +inf), so two windowless links always overlap.
func WindowsOverlap(a, b ExpenseCategory) bool {
	const minI = int64(-1) << 62
	const maxI = int64(1)<<62 - 1
	lo1, hi1 := minI, maxI
	if a.StartDate != nil {
		lo1 = *a.StartDate
	}
	if a.EndDate != nil {
		hi1 = *a.EndDate
	}
	lo2, hi2 := minI, maxI
	if b.StartDate != nil {
		lo2 = *b.StartDate
	}
	if b.EndDate != nil {
		hi2 = *b.EndDate
	}
	return maxInt(lo1, lo2) <= minInt(hi1, hi2)
}

type TransferExclusion struct {
	TransactionID string `json:"transaction_id"`
	CreatedAt     int64  `json:"created_at"`
}

func maxInt(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
func minInt(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
