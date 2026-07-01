package service

import (
	"context"
	"strings"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/zillow"
)

// ZillowAvailable reports whether a Chromium-family browser (the peer
// dependency) is installed.
func (s *Service) ZillowAvailable() bool { return zillow.ChromeAvailable() }

// FetchZillowValuation looks up the current Zestimate for a mortgage's property
// and stores it as a "zillow"-sourced valuation dated today, replacing any
// earlier Zillow reading from the same day. Prefers the exact Zillow URL over
// the address. Returns a *zillow.Error (with a Code) on failure.
func (s *Service) FetchZillowValuation(ctx context.Context, mortgageID string) (zillow.Result, error) {
	m, err := s.findMortgage(mortgageID)
	if err != nil {
		return zillow.Result{}, err
	}
	target := ""
	if m.ZillowURL != nil {
		target = strings.TrimSpace(*m.ZillowURL)
	}
	if target == "" && m.Address != nil {
		target = strings.TrimSpace(*m.Address)
	}

	res, err := zillow.FetchZestimate(ctx, target)
	if err != nil {
		return zillow.Result{}, err
	}
	if err := s.upsertZillowValuation(mortgageID, res.Value); err != nil {
		return zillow.Result{}, err
	}
	return res, nil
}

func (s *Service) upsertZillowValuation(mortgageID string, value float64) error {
	now := time.Now()
	vals, err := s.db.Valuations()
	if err != nil {
		return err
	}
	id := newID()
	for _, v := range vals {
		if v.MortgageID == mortgageID && v.Source != nil && *v.Source == "zillow" && sameDay(v.AsDate(), now) {
			id = v.ID
			break
		}
	}
	src := "zillow"
	return s.db.SaveValuation(model.HomeValuation{
		ID: id, MortgageID: mortgageID, Date: now.Unix(), Value: value, Source: &src,
	})
}

func sameDay(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	return ay == by && am == bm && ad == bd
}
