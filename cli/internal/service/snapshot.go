package service

import (
	"github.com/RomneyDa/phinny/cli/internal/analytics"
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/mortgage"
)

// Snapshot is a consistent in-memory view of the database used by reads and the
// category/transfer resolution logic (mirrors AppState's derived caches, built
// per request rather than cached, since SQLite reads are cheap).
type Snapshot struct {
	Accounts           []model.Account
	Transactions       []model.Transaction
	Categories         []model.SpendCategory
	ExpenseCategories  []model.ExpenseCategory
	TransferExclusions map[string]bool

	categoriesByID map[string]model.SpendCategory
	linksByTxn     map[string][]model.ExpenseCategory
}

// snapshot loads the data needed for resolution + analytics.
func (s *Service) snapshot() (*Snapshot, error) {
	accounts, err := s.db.Accounts()
	if err != nil {
		return nil, err
	}
	txns, err := s.db.Transactions()
	if err != nil {
		return nil, err
	}
	cats, err := s.db.Categories()
	if err != nil {
		return nil, err
	}
	links, err := s.db.ExpenseCategories()
	if err != nil {
		return nil, err
	}
	excl, err := s.db.TransferExclusions()
	if err != nil {
		return nil, err
	}

	snap := &Snapshot{
		Accounts:           accounts,
		Transactions:       txns,
		Categories:         cats,
		ExpenseCategories:  links,
		TransferExclusions: map[string]bool{},
		categoriesByID:     map[string]model.SpendCategory{},
		linksByTxn:         map[string][]model.ExpenseCategory{},
	}
	for _, c := range cats {
		snap.categoriesByID[c.ID] = c
	}
	for _, l := range links {
		snap.linksByTxn[l.TransactionID] = append(snap.linksByTxn[l.TransactionID], l)
	}
	for _, x := range excl {
		snap.TransferExclusions[x.TransactionID] = true
	}
	return snap, nil
}

// links returns all links attached to a transaction (any window).
func (snap *Snapshot) links(txnID string) []model.ExpenseCategory {
	return snap.linksByTxn[txnID]
}

// applicableLinks returns the links whose window contains the transaction's date.
func (snap *Snapshot) applicableLinks(t model.Transaction) []model.ExpenseCategory {
	var out []model.ExpenseCategory
	for _, l := range snap.links(t.ID) {
		if l.Applies(t.Posted) {
			out = append(out, l)
		}
	}
	return out
}

// effectiveCategory returns the single category shown for a transaction: manual
// wins over auto, then the most recent link.
func (snap *Snapshot) effectiveCategory(t model.Transaction) *model.SpendCategory {
	applicable := snap.applicableLinks(t)
	if len(applicable) == 0 {
		return nil
	}
	best := applicable[0]
	for _, l := range applicable[1:] {
		if linkGreater(l, best) {
			best = l
		}
	}
	if c, ok := snap.categoriesByID[best.CategoryID]; ok {
		return &c
	}
	return nil
}

// linkGreater reports whether a ranks higher than b (manual over auto, then newer).
func linkGreater(a, b model.ExpenseCategory) bool {
	if a.IsAuto != b.IsAuto {
		return !a.IsAuto // manual (isAuto=false) ranks higher
	}
	return a.CreatedAt >= b.CreatedAt
}

// appliedCategories returns every applicable category for a transaction.
func (snap *Snapshot) appliedCategories(t model.Transaction) []model.SpendCategory {
	var out []model.SpendCategory
	for _, l := range snap.applicableLinks(t) {
		if c, ok := snap.categoriesByID[l.CategoryID]; ok {
			out = append(out, c)
		}
	}
	return out
}

// categoryLabel is the label used by the spending chart.
func (snap *Snapshot) categoryLabel(t model.Transaction) string {
	if c := snap.effectiveCategory(t); c != nil {
		return c.Name
	}
	return t.GroupLabel()
}

// isTransfer reports whether the transaction's effective category is a transfer.
func (snap *Snapshot) isTransfer(t model.Transaction) bool {
	c := snap.effectiveCategory(t)
	return c != nil && c.IsTransfer
}

// similarTransactions returns transactions sharing this one's account +
// normalized title (including itself).
func (snap *Snapshot) similarTransactions(t model.Transaction) []model.Transaction {
	sig := mortgage.Normalize(t.PayeeOrDescription())
	if sig == "" {
		return []model.Transaction{t}
	}
	var out []model.Transaction
	for _, x := range snap.Transactions {
		if x.AccountID == t.AccountID && mortgage.Normalize(x.PayeeOrDescription()) == sig {
			out = append(out, x)
		}
	}
	return out
}

// visibleAccounts/visibleTransactions exclude hidden accounts.
func (snap *Snapshot) hiddenAccountIDs() map[string]bool {
	hidden := map[string]bool{}
	for _, a := range snap.Accounts {
		if a.Hidden {
			hidden[a.ID] = true
		}
	}
	return hidden
}

func (snap *Snapshot) visibleAccounts() []model.Account {
	hidden := snap.hiddenAccountIDs()
	if len(hidden) == 0 {
		return snap.Accounts
	}
	var out []model.Account
	for _, a := range snap.Accounts {
		if !hidden[a.ID] {
			out = append(out, a)
		}
	}
	return out
}

func (snap *Snapshot) visibleTransactions() []model.Transaction {
	hidden := snap.hiddenAccountIDs()
	if len(hidden) == 0 {
		return snap.Transactions
	}
	var out []model.Transaction
	for _, t := range snap.Transactions {
		if !hidden[t.AccountID] {
			out = append(out, t)
		}
	}
	return out
}

// spendingTransactions are visible transactions that are not transfers.
func (snap *Snapshot) spendingTransactions() []model.Transaction {
	var out []model.Transaction
	for _, t := range snap.visibleTransactions() {
		if !snap.isTransfer(t) {
			out = append(out, t)
		}
	}
	return out
}

// Dashboard bundles the derived analytics the app/agents render.
type Dashboard struct {
	Summary      analytics.Summary        `json:"summary"`
	MonthlyFlows []analytics.MonthlyFlow  `json:"monthly_flows"`
	TopSpending  []analytics.CategorySpend `json:"top_spending"`
}

// Dashboard computes the summary cards + chart series.
func (s *Service) Dashboard() (Dashboard, error) {
	snap, err := s.snapshot()
	if err != nil {
		return Dashboard{}, err
	}
	now := s.now()
	spending := snap.spendingTransactions()
	return Dashboard{
		Summary:      analytics.SummaryOf(snap.visibleAccounts(), spending, now),
		MonthlyFlows: analytics.MonthlyFlows(spending, 12, now),
		TopSpending:  analytics.TopSpending(spending, 30, 7, now, snap.categoryLabel),
	}, nil
}
