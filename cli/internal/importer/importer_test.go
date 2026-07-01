package importer

import (
	"math"
	"testing"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

func TestParseCSVNegatesAndHashesStably(t *testing.T) {
	csv := "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD)\n" +
		"06/01/2026,06/02/2026,APPLE STORE,Apple,Shopping,Purchase,52.30\n"
	r, err := Parse([]byte(csv), "statement.csv")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(r.Transactions) != 1 {
		t.Fatalf("want 1 txn, got %d", len(r.Transactions))
	}
	tx := r.Transactions[0]
	if tx.Amount != -52.30 { // Apple shows purchases positive; we negate to spending
		t.Errorf("amount: want -52.30, got %v", tx.Amount)
	}
	if tx.AccountID != model.StatementAccountID {
		t.Errorf("account: want %s, got %s", model.StatementAccountID, tx.AccountID)
	}
	if tx.Payee == nil || *tx.Payee != "Apple" {
		t.Errorf("payee: want Apple, got %v", tx.Payee)
	}
	if tx.Category == nil || *tx.Category != "Shopping" {
		t.Errorf("category: want Shopping, got %v", tx.Category)
	}

	// Re-parsing the same row must produce the same id (deterministic FNV hash).
	r2, _ := Parse([]byte(csv), "statement.csv")
	if r2.Transactions[0].ID != tx.ID {
		t.Errorf("content hash not stable: %s vs %s", tx.ID, r2.Transactions[0].ID)
	}
}

func TestParseOFXKeepsDebitSign(t *testing.T) {
	ofx := `OFXHEADER:100
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-12.34<FITID>ABC123<NAME>Coffee</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-100.00<DTASOF>20260601</LEDGERBAL>
</STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`
	r, err := Parse([]byte(ofx), "statement.ofx")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(r.Transactions) != 1 {
		t.Fatalf("want 1 txn, got %d", len(r.Transactions))
	}
	tx := r.Transactions[0]
	if math.Abs(tx.Amount-(-12.34)) > 1e-9 { // OFX TRNAMT already debit-negative
		t.Errorf("amount: want -12.34, got %v", tx.Amount)
	}
	if tx.ProviderID != "ABC123" {
		t.Errorf("fitid: want ABC123, got %s", tx.ProviderID)
	}
	if tx.ID != model.StatementAccountID+"|ABC123" {
		t.Errorf("id: got %s", tx.ID)
	}
}
