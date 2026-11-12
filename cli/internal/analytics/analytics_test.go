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
