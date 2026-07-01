package service

import (
	"fmt"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/mortgage"
)

// MakeDraftMortgage returns a sensible new-mortgage template.
func (s *Service) MakeDraftMortgage() model.Mortgage {
	now := s.epoch()
	return model.Mortgage{
		ID: newID(), Name: "", Principal: 400000, DownKind: "percent", DownValue: 20,
		AnnualRate: 6.5, TermMonths: 360, StartDate: now, CreatedAt: now,
	}
}

// UpsertMortgage saves a mortgage.
func (s *Service) UpsertMortgage(m model.Mortgage) (model.Mortgage, error) {
	if m.ID == "" {
		m.ID = newID()
	}
	if m.CreatedAt == 0 {
		m.CreatedAt = s.epoch()
	}
	if m.DownKind == "" {
		m.DownKind = "percent"
	}
	if err := s.db.SaveMortgage(m); err != nil {
		return model.Mortgage{}, err
	}
	return m, nil
}

func (s *Service) DeleteMortgage(id string) error { return s.db.DeleteMortgage(id) }

func (s *Service) AddRateChange(mortgageID string, date int64, annualRate float64) error {
	return s.db.SaveRateChange(model.MortgageRateChange{
		ID: newID(), MortgageID: mortgageID, EffectiveDate: date, AnnualRate: annualRate,
	})
}

func (s *Service) AddValuation(mortgageID string, date int64, value float64, source *string) error {
	return s.db.SaveValuation(model.HomeValuation{
		ID: newID(), MortgageID: mortgageID, Date: date, Value: value, Source: source,
	})
}

func (s *Service) AddManualTxn(mortgageID string, date int64, amount float64, note *string) error {
	return s.db.SaveManualTxn(model.MortgageManualTxn{
		ID: newID(), MortgageID: mortgageID, Date: date, Amount: amount, Note: note,
	})
}

func (s *Service) DeleteMortgageChild(table, id string) error {
	return s.db.DeleteMortgageChild(table, id)
}

// ---- payment linking ----------------------------------------------------

// MarkAsPayment marks a transaction as a mortgage's payment, then auto-links
// every similar expense. Returns the total number of linked transactions.
func (s *Service) MarkAsPayment(txnID, mortgageID string) (int, error) {
	txns, err := s.db.Transactions()
	if err != nil {
		return 0, err
	}
	var txn *model.Transaction
	for i := range txns {
		if txns[i].ID == txnID {
			txn = &txns[i]
			break
		}
	}
	if txn == nil {
		return 0, fmt.Errorf("transaction not found: %s", txnID)
	}
	m, err := s.findMortgage(mortgageID)
	if err != nil {
		return 0, err
	}
	payee := txn.PayeeOrDescription()
	m.PaymentPayee = &payee
	amt := txn.Amount
	m.PaymentAmount = &amt
	m.PaymentAccountID = &txn.AccountID
	if err := s.db.SaveMortgage(m); err != nil {
		return 0, err
	}
	if err := s.relinkPayments(m, txns); err != nil {
		return 0, err
	}
	links, err := s.db.PaymentLinks()
	if err != nil {
		return 0, err
	}
	count := 0
	for _, l := range links {
		if l.MortgageID == mortgageID {
			count++
		}
	}
	return count, nil
}

// ApplyDetectedPayment applies a detected recurring payment to a mortgage.
func (s *Service) ApplyDetectedPayment(mortgageID, payee string, amount float64) error {
	m, err := s.findMortgage(mortgageID)
	if err != nil {
		return err
	}
	m.PaymentPayee = &payee
	m.PaymentAmount = &amount
	if err := s.db.SaveMortgage(m); err != nil {
		return err
	}
	txns, err := s.db.Transactions()
	if err != nil {
		return err
	}
	return s.relinkPayments(m, txns)
}

// DetectPayment finds a likely recurring payment near the scheduled amount.
func (s *Service) DetectPayment(mortgageID string) (*mortgage.Suggestion, error) {
	sum, err := s.MortgageSummary(mortgageID, s.now())
	if err != nil {
		return nil, err
	}
	txns, err := s.db.Transactions()
	if err != nil {
		return nil, err
	}
	return mortgage.Detect(txns, sum.MonthlyPayment), nil
}

// UnlinkPayment unlinks a single transaction from being a mortgage payment.
func (s *Service) UnlinkPayment(txnID string) error {
	return s.db.RemovePaymentLink(txnID)
}

func (s *Service) relinkPayments(m model.Mortgage, txns []model.Transaction) error {
	if err := s.db.RemovePaymentLinks(m.ID); err != nil {
		return err
	}
	matched := mortgage.Matches(txns, m)
	links := make([]model.MortgagePaymentLink, 0, len(matched))
	for _, t := range matched {
		links = append(links, model.MortgagePaymentLink{TransactionID: t.ID, MortgageID: m.ID})
	}
	return s.db.AddPaymentLinks(links)
}

// ---- summary / schedule -------------------------------------------------

// MortgageSummary computes the headline numbers for a mortgage as of `now`.
func (s *Service) MortgageSummary(mortgageID string, now time.Time) (mortgage.Summary, error) {
	m, err := s.findMortgage(mortgageID)
	if err != nil {
		return mortgage.Summary{}, err
	}
	rc, ex, vals, err := s.mortgageChildren(mortgageID)
	if err != nil {
		return mortgage.Summary{}, err
	}
	return mortgage.SummaryOf(m, rc, ex, vals, now), nil
}

// MortgageSchedule computes the full amortization schedule for a mortgage.
func (s *Service) MortgageSchedule(mortgageID string) ([]mortgage.Point, error) {
	m, err := s.findMortgage(mortgageID)
	if err != nil {
		return nil, err
	}
	rc, ex, vals, err := s.mortgageChildren(mortgageID)
	if err != nil {
		return nil, err
	}
	return mortgage.Schedule(m, rc, ex, vals), nil
}

func (s *Service) findMortgage(id string) (model.Mortgage, error) {
	ms, err := s.db.Mortgages()
	if err != nil {
		return model.Mortgage{}, err
	}
	for _, m := range ms {
		if m.ID == id {
			return m, nil
		}
	}
	return model.Mortgage{}, fmt.Errorf("mortgage not found: %s", id)
}

func (s *Service) mortgageChildren(id string) ([]model.MortgageRateChange, []model.MortgageManualTxn, []model.HomeValuation, error) {
	allRC, err := s.db.RateChanges()
	if err != nil {
		return nil, nil, nil, err
	}
	allEx, err := s.db.ManualTxns()
	if err != nil {
		return nil, nil, nil, err
	}
	allVals, err := s.db.Valuations()
	if err != nil {
		return nil, nil, nil, err
	}
	var rc []model.MortgageRateChange
	for _, x := range allRC {
		if x.MortgageID == id {
			rc = append(rc, x)
		}
	}
	var ex []model.MortgageManualTxn
	for _, x := range allEx {
		if x.MortgageID == id {
			ex = append(ex, x)
		}
	}
	var vals []model.HomeValuation
	for _, x := range allVals {
		if x.MortgageID == id {
			vals = append(vals, x)
		}
	}
	return rc, ex, vals, nil
}
