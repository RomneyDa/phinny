// Package importer parses an Apple Card statement export (CSV/OFX/QFX/QBO) into
// Phinny's storage models. Pure, like analytics (mirrors StatementImporter.swift).
//
// Imported rows reuse the SimpleFIN sign convention (negative = spending) and the
// "accountId|providerId" id scheme, so categorization, transfers, and charts
// treat Apple Card transactions exactly like synced ones.
package importer

import (
	"encoding/csv"
	"fmt"
	"hash/fnv"
	"strconv"
	"strings"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// Result is the parsed statement, ready for store.Replace.
type Result struct {
	Accounts     []model.Account     `json:"accounts"`
	Transactions []model.Transaction `json:"transactions"`
}

// Parse parses a statement file. `filename` only selects the parser by
// extension; the content is what is trusted.
func Parse(data []byte, filename string) (Result, error) {
	ext := strings.ToLower(extOf(filename))
	text := string(data)

	var res Result
	var err error
	switch ext {
	case "ofx", "qfx", "qbo":
		res, err = parseOFX(text)
	case "csv":
		res, err = parseCSV(text)
	case "":
		if strings.Contains(text, "<OFX>") || strings.Contains(strings.ToUpper(text), "OFXHEADER") {
			res, err = parseOFX(text)
		} else {
			res, err = parseCSV(text)
		}
	default:
		return Result{}, fmt.Errorf("Phinny can't read a .%s file. Export your Apple Card statement as CSV, OFX, QFX, or QBO.", ext)
	}
	if err != nil {
		return Result{}, err
	}
	if len(res.Transactions) == 0 {
		return Result{}, fmt.Errorf("No transactions were found in that file.")
	}
	return res, nil
}

func extOf(filename string) string {
	i := strings.LastIndex(filename, ".")
	if i < 0 || i == len(filename)-1 {
		return ""
	}
	return filename[i+1:]
}

// ---- OFX / QFX / QBO ----------------------------------------------------

func parseOFX(text string) (Result, error) {
	var txns []model.Transaction
	for _, block := range blocksOf("STMTTRN", text) {
		fitid := tagValue("FITID", block)
		if fitid == "" {
			continue
		}
		amount, _ := strconv.ParseFloat(tagValue("TRNAMT", block), 64)
		posted := ofxDate(tagValue("DTPOSTED", block))
		name := tagValue("NAME", block)
		memo := tagValue("MEMO", block)
		desc := name
		if desc == "" {
			desc = memo
		}
		t := model.Transaction{
			ID:          model.StatementAccountID + "|" + fitid,
			ProviderID:  fitid,
			AccountID:   model.StatementAccountID,
			Posted:      posted,
			Amount:      amount, // OFX TRNAMT is already debit-negative
			Description: desc,
			Pending:     false,
		}
		if name != "" {
			t.Payee = &name
		}
		if memo != "" {
			t.Memo = &memo
		}
		txns = append(txns, t)
	}

	balance := 0.0
	var balanceDate *int64
	if bals := blocksOf("LEDGERBAL", text); len(bals) > 0 {
		balance, _ = strconv.ParseFloat(tagValue("BALAMT", bals[0]), 64)
		if d := ofxDate(tagValue("DTASOF", bals[0])); d != 0 {
			balanceDate = &d
		}
	}
	currency := tagValue("CURDEF", text)
	if currency == "" {
		currency = "USD"
	}
	acct := model.Account{
		ID: model.StatementAccountID, Name: model.StatementAccountName, OrgName: model.StatementAccountName,
		Currency: currency, Balance: balance, BalanceDate: balanceDate,
	}
	return Result{Accounts: []model.Account{acct}, Transactions: txns}, nil
}

// blocksOf returns all <TAG>...</TAG> block contents (case-insensitive tag).
func blocksOf(tag, text string) []string {
	open := "<" + tag + ">"
	close := "</" + tag + ">"
	upper := strings.ToUpper(text)
	var out []string
	start := 0
	for {
		oi := strings.Index(upper[start:], open)
		if oi < 0 {
			break
		}
		oi += start
		contentStart := oi + len(open)
		ci := strings.Index(upper[contentStart:], close)
		if ci < 0 {
			break
		}
		ci += contentStart
		out = append(out, text[contentStart:ci])
		start = ci + len(close)
	}
	return out
}

// tagValue reads a leaf OFX element: from after <TAG> up to the next < or EOL.
func tagValue(tag, block string) string {
	upper := strings.ToUpper(block)
	marker := "<" + tag + ">"
	i := strings.Index(upper, marker)
	if i < 0 {
		return ""
	}
	rest := block[i+len(marker):]
	end := len(rest)
	for j, r := range rest {
		if r == '<' || r == '\n' || r == '\r' {
			end = j
			break
		}
	}
	return strings.TrimSpace(rest[:end])
}

// ofxDate parses YYYYMMDD (optionally followed by time/tz) to local-midnight epoch.
func ofxDate(raw string) int64 {
	if len(raw) < 8 {
		return 0
	}
	d, err := time.ParseInLocation("20060102", raw[:8], time.Local)
	if err != nil {
		return 0
	}
	return d.Unix()
}

// ---- CSV (Apple Card export) --------------------------------------------

func parseCSV(text string) (Result, error) {
	r := csv.NewReader(strings.NewReader(text))
	r.FieldsPerRecord = -1
	r.LazyQuotes = true
	records, err := r.ReadAll()
	if err != nil {
		return Result{}, fmt.Errorf("Could not read the statement: %v", err)
	}
	// Drop fully-empty rows (mirrors the Swift parser).
	var rows [][]string
	for _, row := range records {
		nonEmpty := false
		for _, f := range row {
			if strings.TrimSpace(f) != "" {
				nonEmpty = true
				break
			}
		}
		if nonEmpty {
			rows = append(rows, row)
		}
	}
	if len(rows) == 0 {
		return Result{}, fmt.Errorf("No transactions were found in that file.")
	}
	header := rows[0]

	col := func(names ...string) int {
		for i, h := range header {
			norm := strings.TrimSpace(strings.ToLower(h))
			for _, n := range names {
				if norm == n || strings.HasPrefix(norm, n) {
					return i
				}
			}
		}
		return -1
	}
	amountIdx := col("amount (usd)", "amount")
	if amountIdx < 0 {
		return Result{}, fmt.Errorf("CSV is missing an Amount column.")
	}
	dateIdx := col("transaction date", "date")
	descIdx := col("description")
	merchantIdx := col("merchant")
	categoryIdx := col("category")

	field := func(row []string, idx int) string {
		if idx < 0 || idx >= len(row) {
			return ""
		}
		return strings.TrimSpace(row[idx])
	}

	var txns []model.Transaction
	for _, row := range rows[1:] {
		if amountIdx >= len(row) {
			continue
		}
		amountRaw := strings.TrimSpace(strings.NewReplacer("$", "", ",", "").Replace(row[amountIdx]))
		parsed, err := strconv.ParseFloat(amountRaw, 64)
		if err != nil {
			continue
		}
		amount := -parsed // purchase (+) -> spending (-)
		dateStr := field(row, dateIdx)
		posted := csvDate(dateStr)
		merchant := field(row, merchantIdx)
		desc := field(row, descIdx)
		if desc == "" {
			desc = merchant
		}
		providerID := contentHash(dateStr, amountRaw, desc, merchant)
		t := model.Transaction{
			ID:          model.StatementAccountID + "|" + providerID,
			ProviderID:  providerID,
			AccountID:   model.StatementAccountID,
			Posted:      posted,
			Amount:      amount,
			Description: desc,
			Pending:     false,
		}
		if merchant != "" {
			t.Payee = &merchant
		}
		if c := field(row, categoryIdx); c != "" {
			t.Category = &c
		}
		txns = append(txns, t)
	}

	acct := model.Account{
		ID: model.StatementAccountID, Name: model.StatementAccountName, OrgName: model.StatementAccountName,
		Currency: "USD", Balance: 0,
	}
	return Result{Accounts: []model.Account{acct}, Transactions: txns}, nil
}

func csvDate(raw string) int64 {
	if raw == "" {
		return 0
	}
	for _, layout := range []string{"01/02/2006", "2006-01-02", "1/2/2006"} {
		if d, err := time.ParseInLocation(layout, raw, time.Local); err == nil {
			return d.Unix()
		}
	}
	return 0
}

// contentHash is a deterministic 64-bit FNV-1a hash, hex-encoded. Matches the
// Swift implementation (join with the 0x1f unit separator), so re-imports of the
// same CSV row produce the same id.
func contentHash(parts ...string) string {
	h := fnv.New64a()
	h.Write([]byte(strings.Join(parts, "\x1f")))
	return strconv.FormatUint(h.Sum64(), 16)
}
