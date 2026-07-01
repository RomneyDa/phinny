package transfers

import (
	"testing"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

func TestDetectOffsettingPair(t *testing.T) {
	day := int64(86400)
	txns := []model.Transaction{
		{ID: "a", AccountID: "checking", Amount: -500, Posted: 100 * day},
		{ID: "b", AccountID: "savings", Amount: 500, Posted: 101 * day}, // next day, offsetting
		{ID: "c", AccountID: "checking", Amount: -25, Posted: 100 * day}, // unrelated expense
	}
	matched := Detect(txns, DefaultWindowDays)
	if !matched["a"] || !matched["b"] {
		t.Errorf("expected a+b matched, got %v", matched)
	}
	if matched["c"] {
		t.Errorf("c should not be a transfer")
	}
}

func TestDetectIgnoresSameAccountAndFarApart(t *testing.T) {
	day := int64(86400)
	txns := []model.Transaction{
		{ID: "a", AccountID: "checking", Amount: -500, Posted: 100 * day},
		{ID: "b", AccountID: "checking", Amount: 500, Posted: 100 * day}, // same account
		{ID: "c", AccountID: "checking", Amount: -300, Posted: 100 * day},
		{ID: "d", AccountID: "savings", Amount: 300, Posted: 110 * day}, // 10 days later, outside window
	}
	matched := Detect(txns, DefaultWindowDays)
	if len(matched) != 0 {
		t.Errorf("expected no matches, got %v", matched)
	}
}
