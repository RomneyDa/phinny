package analytics

import (
	"math"
	"testing"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// now is mid-month so "this month" and "last month" are both unambiguous.
var testNow = time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)

func epoch(y int, m time.Month, d int) int64 {
	return time.Date(y, m, d, 12, 0, 0, 0, time.UTC).Unix()
}

func closeTo(t *testing.T, label string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 0.005 {
		t.Errorf("%s = %.2f, want %.2f", label, got, want)
	}
}

func testAccounts() []model.Account {
	return []model.Account{
		{ID: "checking", Name: "Checking", OrgName: "Bank", Currency: "USD", Balance: 2000},
		{ID: "card", Name: "Card", OrgName: "Bank", Currency: "USD", Balance: -500},
	}
}

func testTransactions() []model.Transaction {
	return []model.Transaction{
		{ID: "a", AccountID: "checking", Posted: epoch(2026, time.November, 2), Amount: 3000},
		{ID: "b", AccountID: "checking", Posted: epoch(2026, time.November, 5), Amount: -200},
		{ID: "c", AccountID: "card", Posted: epoch(2026, time.November, 6), Amount: -75},
		// Last month: counted in TransactionCount, excluded from month figures.
		{ID: "d", AccountID: "card", Posted: epoch(2026, time.October, 20), Amount: -40},
	}
}

func TestSummaryOfNetWorthDefaultsToBalances(t *testing.T) {
	s := SummaryOf(testAccounts(), testTransactions(), testNow)

	closeTo(t, "TotalBalance", s.TotalBalance, 1500)
	closeTo(t, "CurrentMonthIncome", s.CurrentMonthIncome, 3000)
	closeTo(t, "CurrentMonthExpense", s.CurrentMonthExpense, 275)
	closeTo(t, "CurrentMonthNet", s.CurrentMonthNet, 2725)
	// With no mortgage, net worth must equal the balance total, not zero.
	closeTo(t, "NetWorth", s.NetWorth, 1500)
	closeTo(t, "MortgageEquity", s.MortgageEquity, 0)
	if s.AccountCount != 2 || s.TransactionCount != 4 {
		t.Errorf("counts = (%d, %d), want (2, 4)", s.AccountCount, s.TransactionCount)
	}
}

func TestWithMortgageEquityAddsToNetWorth(t *testing.T) {
	s := SummaryOf(testAccounts(), testTransactions(), testNow).WithMortgageEquity(53825.56)

	closeTo(t, "MortgageEquity", s.MortgageEquity, 53825.56)
	closeTo(t, "NetWorth", s.NetWorth, 55325.56)
	// Equity must not leak into the liquid total or the monthly flows.
	closeTo(t, "TotalBalance", s.TotalBalance, 1500)
	closeTo(t, "CurrentMonthNet", s.CurrentMonthNet, 2725)
}

// Underwater equity is negative, so it has to pull net worth down.
func TestWithMortgageEquityHandlesNegativeEquity(t *testing.T) {
	s := SummaryOf(testAccounts(), testTransactions(), testNow).WithMortgageEquity(-20000)
	closeTo(t, "NetWorth", s.NetWorth, -18500)
}

func TestAccountRollupsSplitsByAccount(t *testing.T) {
	rollups := AccountRollups(testAccounts(), testTransactions(), testNow)

	if len(rollups) != 2 {
		t.Fatalf("len(rollups) = %d, want 2", len(rollups))
	}
	// Sorted by balance descending, so checking leads.
	if rollups[0].AccountID != "checking" || rollups[1].AccountID != "card" {
		t.Fatalf("order = (%s, %s), want (checking, card)", rollups[0].AccountID, rollups[1].AccountID)
	}

	checking, card := rollups[0], rollups[1]
	closeTo(t, "checking.Balance", checking.Balance, 2000)
	closeTo(t, "checking.CurrentMonthIncome", checking.CurrentMonthIncome, 3000)
	closeTo(t, "checking.CurrentMonthExpense", checking.CurrentMonthExpense, 200)
	closeTo(t, "checking.CurrentMonthNet", checking.CurrentMonthNet, 2800)
	if checking.TransactionCount != 2 {
		t.Errorf("checking.TransactionCount = %d, want 2", checking.TransactionCount)
	}
	if checking.Name != "Checking" || checking.OrgName != "Bank" || checking.Currency != "USD" {
		t.Errorf("checking identity not carried through: %+v", checking)
	}

	closeTo(t, "card.Balance", card.Balance, -500)
	closeTo(t, "card.CurrentMonthExpense", card.CurrentMonthExpense, 75)
	// The October row counts toward the total but not the month.
	if card.TransactionCount != 2 {
		t.Errorf("card.TransactionCount = %d, want 2", card.TransactionCount)
	}
}

// The rollups are the aggregate broken apart, so they must add back up to it.
func TestAccountRollupsAgreeWithSummary(t *testing.T) {
	accounts, txns := testAccounts(), testTransactions()
	s := SummaryOf(accounts, txns, testNow)
	rollups := AccountRollups(accounts, txns, testNow)

	var balance, income, expense float64
	count := 0
	for _, r := range rollups {
		balance += r.Balance
		income += r.CurrentMonthIncome
		expense += r.CurrentMonthExpense
		count += r.TransactionCount
	}
	closeTo(t, "sum(Balance)", balance, s.TotalBalance)
	closeTo(t, "sum(CurrentMonthIncome)", income, s.CurrentMonthIncome)
	closeTo(t, "sum(CurrentMonthExpense)", expense, s.CurrentMonthExpense)
	if count != s.TransactionCount {
		t.Errorf("sum(TransactionCount) = %d, want %d", count, s.TransactionCount)
	}
}

// A transaction whose account was filtered out (hidden) must neither invent a
// rollup nor get charged to one of the accounts that were passed in.
func TestAccountRollupsIgnoresUnknownAccounts(t *testing.T) {
	clean := AccountRollups(testAccounts(), testTransactions(), testNow)

	withOrphan := AccountRollups(testAccounts(), append(testTransactions(), model.Transaction{
		ID: "orphan", AccountID: "hidden-account",
		Posted: epoch(2026, time.November, 7), Amount: -9999,
	}), testNow)

	if len(withOrphan) != len(clean) {
		t.Fatalf("len(rollups) = %d, want %d", len(withOrphan), len(clean))
	}
	for i := range withOrphan {
		if withOrphan[i].AccountID == "hidden-account" {
			t.Fatal("rollup created for an account that was not passed in")
		}
		if withOrphan[i] != clean[i] {
			t.Errorf("rollup %s changed: %+v, want %+v",
				clean[i].AccountID, withOrphan[i], clean[i])
		}
	}
}

func TestAccountRollupsWithNoAccounts(t *testing.T) {
	if got := AccountRollups(nil, testTransactions(), testNow); len(got) != 0 {
		t.Errorf("len = %d, want 0", len(got))
	}
}

func TestNetWorthSeriesWalksBalancesBackwards(t *testing.T) {
	// One account at 2000 today, with 500 of income this month and 300 of
	// spending last month, so the end of each earlier month is reconstructable.
	accounts := []model.Account{{ID: "checking", Balance: 2000}}
	txns := []model.Transaction{
		{ID: "a", AccountID: "checking", Posted: epoch(2026, time.November, 5), Amount: 500},
		{ID: "b", AccountID: "checking", Posted: epoch(2026, time.October, 20), Amount: -300},
		// An early September row so all three months have data behind them.
		{ID: "c", AccountID: "checking", Posted: epoch(2026, time.September, 2), Amount: 0},
	}

	pts := NetWorthSeries(accounts, txns, 3, testNow, nil)
	if len(pts) != 3 {
		t.Fatalf("len = %d, want 3", len(pts))
	}

	// Oldest first: September end, October end, now.
	closeTo(t, "Sep end", pts[0].Accounts, 1800) // before the -300 and the +500
	closeTo(t, "Oct end", pts[1].Accounts, 1500) // the -300 has landed
	closeTo(t, "now", pts[2].Accounts, 2000)     // everything has landed

	// The last point has to agree with the headline card.
	s := SummaryOf(accounts, txns, testNow)
	closeTo(t, "last point vs summary", pts[len(pts)-1].NetWorth, s.NetWorth)
}

func TestNetWorthSeriesAddsEquity(t *testing.T) {
	accounts := []model.Account{{ID: "checking", Balance: 1000}}
	// Equity that rises steadily with time. Day granularity, not month, so the
	// final two points (the 1st and partway through the current month) differ.
	equityAt := func(at time.Time) float64 {
		return float64(at.Unix()) / 86400
	}
	pts := NetWorthSeries(accounts, nil, 3, testNow, equityAt)

	for _, p := range pts {
		closeTo(t, "NetWorth = Accounts + Equity", p.NetWorth, p.Accounts+p.Equity)
	}
	if !(pts[0].Equity < pts[1].Equity && pts[1].Equity < pts[2].Equity) {
		t.Errorf("equity should rise across points, got %v %v %v",
			pts[0].Equity, pts[1].Equity, pts[2].Equity)
	}
}

// Transfers net to zero across the two accounts, so including both legs must
// leave the reconstruction unchanged.
func TestNetWorthSeriesUnaffectedByTransfers(t *testing.T) {
	accounts := []model.Account{
		{ID: "checking", Balance: 1000},
		{ID: "savings", Balance: 500},
	}
	base := []model.Transaction{
		{ID: "pay", AccountID: "checking", Posted: epoch(2026, time.October, 2), Amount: 900},
	}
	withTransfer := append(append([]model.Transaction{}, base...),
		model.Transaction{ID: "out", AccountID: "checking", Posted: epoch(2026, time.October, 15), Amount: -200},
		model.Transaction{ID: "in", AccountID: "savings", Posted: epoch(2026, time.October, 15), Amount: 200},
	)

	a := NetWorthSeries(accounts, base, 3, testNow, nil)
	b := NetWorthSeries(accounts, withTransfer, 3, testNow, nil)
	for i := range a {
		closeTo(t, "point unchanged by a transfer", b[i].Accounts, a[i].Accounts)
	}
}

func TestNetWorthSeriesMonthsAreSequential(t *testing.T) {
	pts := NetWorthSeries([]model.Account{{ID: "a", Balance: 10}}, nil, 6, testNow, nil)
	if len(pts) != 6 {
		t.Fatalf("len = %d, want 6", len(pts))
	}
	for i := 1; i < len(pts); i++ {
		if pts[i].Month <= pts[i-1].Month {
			t.Fatalf("months not ascending at %d: %d then %d", i, pts[i-1].Month, pts[i].Month)
		}
	}
	last := time.Unix(pts[len(pts)-1].Month, 0).UTC()
	if last.Month() != time.November || last.Year() != 2026 {
		t.Errorf("last month = %v, want November 2026", last)
	}
}

// The provider only returns a window of history. Months before the first
// transaction have nothing to reconstruct from, so drawing them would be a
// flat line that reads as "my balance did not move".
func TestNetWorthSeriesStopsAtTheOldestTransaction(t *testing.T) {
	accounts := []model.Account{{ID: "checking", Balance: 2000}}
	txns := []model.Transaction{
		{ID: "a", AccountID: "checking", Posted: epoch(2026, time.October, 3), Amount: 500},
	}

	pts := NetWorthSeries(accounts, txns, 12, testNow, nil)
	if len(pts) == 0 {
		t.Fatal("no points")
	}
	first := time.Unix(pts[0].Month, 0).UTC()
	if first.Before(time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("series starts %v, which predates the oldest transaction", first)
	}
	if len(pts) > 3 {
		t.Errorf("len = %d, want at most 3 months of reconstructable history", len(pts))
	}
}

// A transaction dated in the future must not drag the current point away from
// the summary card, which reports balances as the bank reports them.
func TestNetWorthSeriesLastPointMatchesCurrentBalances(t *testing.T) {
	accounts := []model.Account{{ID: "checking", Balance: 2000}}
	txns := []model.Transaction{
		{ID: "past", AccountID: "checking", Posted: epoch(2026, time.October, 3), Amount: 500},
		{ID: "future", AccountID: "checking", Posted: epoch(2026, time.December, 20), Amount: -1434.34},
	}

	pts := NetWorthSeries(accounts, txns, 6, testNow, nil)
	last := pts[len(pts)-1]
	closeTo(t, "last point", last.Accounts, 2000)
	closeTo(t, "last point vs summary", last.NetWorth, SummaryOf(accounts, txns, testNow).NetWorth)
}
