package mortgage

import (
	"math"
	"testing"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

func TestPaymentMatchesKnownFigure(t *testing.T) {
	// $300k, 6% annual (0.5% monthly), 30 years -> ~$1798.65/mo.
	got := Payment(300000, 0.06/12, 360)
	if math.Abs(got-1798.65) > 0.5 {
		t.Errorf("payment: want ~1798.65, got %.2f", got)
	}
}

func TestScheduleAmortizesToZero(t *testing.T) {
	m := model.Mortgage{
		ID: "m1", Principal: 300000, DownKind: "percent", DownValue: 20,
		AnnualRate: 6, TermMonths: 360, StartDate: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC).Unix(),
	}
	pts := Schedule(m, nil, nil, nil)
	if len(pts) == 0 {
		t.Fatal("empty schedule")
	}
	last := pts[len(pts)-1]
	if last.Balance > 1.0 {
		t.Errorf("loan should be paid off, final balance %.2f", last.Balance)
	}
	// Purchase price = principal / (1 - 0.20) = 375000.
	if math.Abs(m.PurchasePrice()-375000) > 1 {
		t.Errorf("purchase price: want 375000, got %.2f", m.PurchasePrice())
	}
}

func TestNormalizeStripsPunctuation(t *testing.T) {
	if got := Normalize("  WELLS-FARGO  Home #123  "); got != "wells fargo home 123" {
		t.Errorf("normalize: got %q", got)
	}
}
