package service

import (
	"time"

	"github.com/RomneyDa/phinny/cli/internal/config"
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/mortgage"
)

// FullState is the one-shot snapshot the macOS app loads after every mutation:
// every raw array plus the derived dashboard and per-mortgage summaries/
// schedules, so the app makes a single round trip per reload.
type FullState struct {
	Mode            string `json:"mode"`
	Connected       bool   `json:"connected"`
	ImportOnly      bool   `json:"import_only"`
	Writable        bool   `json:"writable"`
	LastSync        *int64 `json:"last_sync"`
	ChromeAvailable bool          `json:"chrome_available"`
	PrimaryCurrency string        `json:"primary_currency"`
	Config          config.Config `json:"config"`

	Accounts           []model.Account           `json:"accounts"`
	Transactions       []model.Transaction       `json:"transactions"`
	Categories         []model.SpendCategory     `json:"categories"`
	ExpenseCategories  []model.ExpenseCategory   `json:"expense_categories"`
	TransferExclusions []model.TransferExclusion `json:"transfer_exclusions"`

	Mortgages    []model.Mortgage            `json:"mortgages"`
	RateChanges  []model.MortgageRateChange  `json:"rate_changes"`
	Valuations   []model.HomeValuation       `json:"valuations"`
	ManualTxns   []model.MortgageManualTxn   `json:"manual_txns"`
	PaymentLinks []model.MortgagePaymentLink `json:"payment_links"`

	Dashboard         Dashboard                    `json:"dashboard"`
	MortgageSummaries map[string]mortgage.Summary  `json:"mortgage_summaries"`
	MortgageSchedules map[string][]mortgage.Point  `json:"mortgage_schedules"`
}

// FullState builds the complete snapshot.
func (s *Service) FullState() (FullState, error) {
	now := time.Now()
	accounts, err := s.db.Accounts()
	if err != nil {
		return FullState{}, err
	}
	txns, err := s.db.Transactions()
	if err != nil {
		return FullState{}, err
	}
	cats, err := s.db.Categories()
	if err != nil {
		return FullState{}, err
	}
	links, err := s.db.ExpenseCategories()
	if err != nil {
		return FullState{}, err
	}
	excl, err := s.db.TransferExclusions()
	if err != nil {
		return FullState{}, err
	}
	mortgages, err := s.db.Mortgages()
	if err != nil {
		return FullState{}, err
	}
	rates, err := s.db.RateChanges()
	if err != nil {
		return FullState{}, err
	}
	vals, err := s.db.Valuations()
	if err != nil {
		return FullState{}, err
	}
	manual, err := s.db.ManualTxns()
	if err != nil {
		return FullState{}, err
	}
	plinks, err := s.db.PaymentLinks()
	if err != nil {
		return FullState{}, err
	}
	dash, err := s.Dashboard()
	if err != nil {
		return FullState{}, err
	}

	st := FullState{
		Mode:               string(s.mode),
		Connected:          s.Connected(),
		ImportOnly:         s.IsImportOnly(),
		Writable:           s.Writable(),
		ChromeAvailable:    s.ZillowAvailable(),
		Accounts:           nz(accounts, []model.Account{}),
		Transactions:       nz(txns, []model.Transaction{}),
		Categories:         nz(cats, []model.SpendCategory{}),
		ExpenseCategories:  nz(links, []model.ExpenseCategory{}),
		TransferExclusions: nz(excl, []model.TransferExclusion{}),
		Mortgages:          nz(mortgages, []model.Mortgage{}),
		RateChanges:        nz(rates, []model.MortgageRateChange{}),
		Valuations:         nz(vals, []model.HomeValuation{}),
		ManualTxns:         nz(manual, []model.MortgageManualTxn{}),
		PaymentLinks:       nz(plinks, []model.MortgagePaymentLink{}),
		Dashboard:          dash,
		Config:             s.cfg,
		MortgageSummaries:  map[string]mortgage.Summary{},
		MortgageSchedules:  map[string][]mortgage.Point{},
	}
	if last := s.LastSync(); last != nil {
		u := last.Unix()
		st.LastSync = &u
	}
	if len(accounts) > 0 {
		st.PrimaryCurrency = accounts[0].Currency
	} else {
		st.PrimaryCurrency = "USD"
	}

	// Per-mortgage summary + schedule (group children once).
	rcByM := groupRates(rates)
	exByM := groupManual(manual)
	vlByM := groupVals(vals)
	for _, m := range mortgages {
		st.MortgageSummaries[m.ID] = mortgage.SummaryOf(m, rcByM[m.ID], exByM[m.ID], vlByM[m.ID], now)
		st.MortgageSchedules[m.ID] = mortgage.Schedule(m, rcByM[m.ID], exByM[m.ID], vlByM[m.ID])
	}
	return st, nil
}

func groupRates(all []model.MortgageRateChange) map[string][]model.MortgageRateChange {
	m := map[string][]model.MortgageRateChange{}
	for _, x := range all {
		m[x.MortgageID] = append(m[x.MortgageID], x)
	}
	return m
}
func groupManual(all []model.MortgageManualTxn) map[string][]model.MortgageManualTxn {
	m := map[string][]model.MortgageManualTxn{}
	for _, x := range all {
		m[x.MortgageID] = append(m[x.MortgageID], x)
	}
	return m
}
func groupVals(all []model.HomeValuation) map[string][]model.HomeValuation {
	m := map[string][]model.HomeValuation{}
	for _, x := range all {
		m[x.MortgageID] = append(m[x.MortgageID], x)
	}
	return m
}

func nz[T any](v, fallback []T) []T {
	if v == nil {
		return fallback
	}
	return v
}
