package store

import (
	"database/sql"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// ---- small null helpers -------------------------------------------------

func nstr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}
func nf64(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}
func ni64(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}
func ptrStr(n sql.NullString) *string {
	if !n.Valid {
		return nil
	}
	v := n.String
	return &v
}
func ptrF64(n sql.NullFloat64) *float64 {
	if !n.Valid {
		return nil
	}
	v := n.Float64
	return &v
}
func ptrI64(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

// ---- accounts -----------------------------------------------------------

func (d *DB) Accounts() ([]model.Account, error) {
	rows, err := d.sql.Query(`SELECT id, name, orgName, currency, balance, availableBalance, balanceDate, hidden FROM account ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Account
	for rows.Next() {
		var a model.Account
		var avail sql.NullFloat64
		var bdate sql.NullInt64
		if err := rows.Scan(&a.ID, &a.Name, &a.OrgName, &a.Currency, &a.Balance, &avail, &bdate, &a.Hidden); err != nil {
			return nil, err
		}
		a.AvailableBalance = ptrF64(avail)
		a.BalanceDate = ptrI64(bdate)
		out = append(out, a)
	}
	return out, rows.Err()
}

func (d *DB) AccountExists(id string) bool {
	var n int
	err := d.sql.QueryRow(`SELECT COUNT(*) FROM account WHERE id = ?`, id).Scan(&n)
	return err == nil && n > 0
}

func (d *DB) SetAccountHidden(id string, hidden bool) error {
	_, err := d.sql.Exec(`UPDATE account SET hidden = ? WHERE id = ?`, hidden, id)
	return err
}

// ---- transactions -------------------------------------------------------

func (d *DB) Transactions() ([]model.Transaction, error) {
	rows, err := d.sql.Query(`SELECT id, providerId, accountId, posted, amount, descriptionText, payee, memo, category, pending FROM transaction_row ORDER BY posted DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Transaction
	for rows.Next() {
		var t model.Transaction
		var payee, memo, cat sql.NullString
		if err := rows.Scan(&t.ID, &t.ProviderID, &t.AccountID, &t.Posted, &t.Amount, &t.Description, &payee, &memo, &cat, &t.Pending); err != nil {
			return nil, err
		}
		t.Payee = ptrStr(payee)
		t.Memo = ptrStr(memo)
		t.Category = ptrStr(cat)
		out = append(out, t)
	}
	return out, rows.Err()
}

func (d *DB) TransactionCount() (int, error) {
	var n int
	err := d.sql.QueryRow(`SELECT COUNT(*) FROM transaction_row`).Scan(&n)
	return n, err
}

// Replace upserts synced accounts + transactions in one transaction. A sync
// supplies hidden=false accounts, so existing "hidden" choices are carried
// forward (a sync must never un-hide an account the user hid).
func (d *DB) Replace(accounts []model.Account, txns []model.Transaction) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	hidden := map[string]bool{}
	rows, err := tx.Query(`SELECT id FROM account WHERE hidden`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		hidden[id] = true
	}
	rows.Close()

	for _, a := range accounts {
		a.Hidden = hidden[a.ID]
		if _, err := tx.Exec(
			`INSERT INTO account (id, name, orgName, currency, balance, availableBalance, balanceDate, hidden)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET name=excluded.name, orgName=excluded.orgName,
			   currency=excluded.currency, balance=excluded.balance,
			   availableBalance=excluded.availableBalance, balanceDate=excluded.balanceDate,
			   hidden=excluded.hidden`,
			a.ID, a.Name, a.OrgName, a.Currency, a.Balance, nf64(a.AvailableBalance), ni64(a.BalanceDate), a.Hidden,
		); err != nil {
			return err
		}
	}
	for _, t := range txns {
		if _, err := tx.Exec(
			`INSERT INTO transaction_row (id, providerId, accountId, posted, amount, descriptionText, payee, memo, category, pending)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET providerId=excluded.providerId, accountId=excluded.accountId,
			   posted=excluded.posted, amount=excluded.amount, descriptionText=excluded.descriptionText,
			   payee=excluded.payee, memo=excluded.memo, category=excluded.category, pending=excluded.pending`,
			t.ID, t.ProviderID, t.AccountID, t.Posted, t.Amount, t.Description, nstr(t.Payee), nstr(t.Memo), nstr(t.Category), t.Pending,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ---- meta ---------------------------------------------------------------

func (d *DB) SetMeta(key, value string) error {
	_, err := d.sql.Exec(
		`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value)
	return err
}

func (d *DB) Meta(key string) (string, bool, error) {
	var v string
	err := d.sql.QueryRow(`SELECT value FROM meta WHERE key = ?`, key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// ---- mortgages ----------------------------------------------------------

func (d *DB) Mortgages() ([]model.Mortgage, error) {
	rows, err := d.sql.Query(`SELECT id, name, address, zillowUrl, principal, downKind, downValue, annualRate, termMonths, startDate, paymentPayee, paymentAmount, paymentAccountId, createdAt FROM mortgage ORDER BY createdAt`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Mortgage
	for rows.Next() {
		var m model.Mortgage
		var addr, zurl, payee, payAcct sql.NullString
		var payAmt sql.NullFloat64
		if err := rows.Scan(&m.ID, &m.Name, &addr, &zurl, &m.Principal, &m.DownKind, &m.DownValue, &m.AnnualRate, &m.TermMonths, &m.StartDate, &payee, &payAmt, &payAcct, &m.CreatedAt); err != nil {
			return nil, err
		}
		m.Address = ptrStr(addr)
		m.ZillowURL = ptrStr(zurl)
		m.PaymentPayee = ptrStr(payee)
		m.PaymentAmount = ptrF64(payAmt)
		m.PaymentAccountID = ptrStr(payAcct)
		out = append(out, m)
	}
	return out, rows.Err()
}

func (d *DB) SaveMortgage(m model.Mortgage) error {
	_, err := d.sql.Exec(
		`INSERT INTO mortgage (id, name, address, zillowUrl, principal, downKind, downValue, annualRate, termMonths, startDate, paymentPayee, paymentAmount, paymentAccountId, createdAt)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET name=excluded.name, address=excluded.address, zillowUrl=excluded.zillowUrl,
		   principal=excluded.principal, downKind=excluded.downKind, downValue=excluded.downValue,
		   annualRate=excluded.annualRate, termMonths=excluded.termMonths, startDate=excluded.startDate,
		   paymentPayee=excluded.paymentPayee, paymentAmount=excluded.paymentAmount,
		   paymentAccountId=excluded.paymentAccountId, createdAt=excluded.createdAt`,
		m.ID, m.Name, nstr(m.Address), nstr(m.ZillowURL), m.Principal, m.DownKind, m.DownValue, m.AnnualRate,
		m.TermMonths, m.StartDate, nstr(m.PaymentPayee), nf64(m.PaymentAmount), nstr(m.PaymentAccountID), m.CreatedAt)
	return err
}

func (d *DB) DeleteMortgage(id string) error {
	_, err := d.sql.Exec(`DELETE FROM mortgage WHERE id = ?`, id)
	return err
}

// DeleteMortgageChild deletes one row from a mortgage child table by id.
// `table` must be one of the known child tables.
func (d *DB) DeleteMortgageChild(table, id string) error {
	switch table {
	case "mortgage_rate_change", "home_valuation", "mortgage_manual_txn":
		_, err := d.sql.Exec(`DELETE FROM `+table+` WHERE id = ?`, id)
		return err
	default:
		return nil
	}
}

func (d *DB) RateChanges() ([]model.MortgageRateChange, error) {
	rows, err := d.sql.Query(`SELECT id, mortgageId, effectiveDate, annualRate FROM mortgage_rate_change ORDER BY effectiveDate`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.MortgageRateChange
	for rows.Next() {
		var r model.MortgageRateChange
		if err := rows.Scan(&r.ID, &r.MortgageID, &r.EffectiveDate, &r.AnnualRate); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (d *DB) SaveRateChange(r model.MortgageRateChange) error {
	_, err := d.sql.Exec(
		`INSERT INTO mortgage_rate_change (id, mortgageId, effectiveDate, annualRate) VALUES (?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET mortgageId=excluded.mortgageId, effectiveDate=excluded.effectiveDate, annualRate=excluded.annualRate`,
		r.ID, r.MortgageID, r.EffectiveDate, r.AnnualRate)
	return err
}

func (d *DB) Valuations() ([]model.HomeValuation, error) {
	rows, err := d.sql.Query(`SELECT id, mortgageId, date, value, source FROM home_valuation ORDER BY date`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.HomeValuation
	for rows.Next() {
		var v model.HomeValuation
		var src sql.NullString
		if err := rows.Scan(&v.ID, &v.MortgageID, &v.Date, &v.Value, &src); err != nil {
			return nil, err
		}
		v.Source = ptrStr(src)
		out = append(out, v)
	}
	return out, rows.Err()
}
func (d *DB) SaveValuation(v model.HomeValuation) error {
	_, err := d.sql.Exec(
		`INSERT INTO home_valuation (id, mortgageId, date, value, source) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET mortgageId=excluded.mortgageId, date=excluded.date, value=excluded.value, source=excluded.source`,
		v.ID, v.MortgageID, v.Date, v.Value, nstr(v.Source))
	return err
}

func (d *DB) ManualTxns() ([]model.MortgageManualTxn, error) {
	rows, err := d.sql.Query(`SELECT id, mortgageId, date, amount, note FROM mortgage_manual_txn ORDER BY date`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.MortgageManualTxn
	for rows.Next() {
		var t model.MortgageManualTxn
		var note sql.NullString
		if err := rows.Scan(&t.ID, &t.MortgageID, &t.Date, &t.Amount, &note); err != nil {
			return nil, err
		}
		t.Note = ptrStr(note)
		out = append(out, t)
	}
	return out, rows.Err()
}
func (d *DB) SaveManualTxn(t model.MortgageManualTxn) error {
	_, err := d.sql.Exec(
		`INSERT INTO mortgage_manual_txn (id, mortgageId, date, amount, note) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET mortgageId=excluded.mortgageId, date=excluded.date, amount=excluded.amount, note=excluded.note`,
		t.ID, t.MortgageID, t.Date, t.Amount, nstr(t.Note))
	return err
}

func (d *DB) PaymentLinks() ([]model.MortgagePaymentLink, error) {
	rows, err := d.sql.Query(`SELECT transactionId, mortgageId FROM mortgage_payment_link`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.MortgagePaymentLink
	for rows.Next() {
		var l model.MortgagePaymentLink
		if err := rows.Scan(&l.TransactionID, &l.MortgageID); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
func (d *DB) AddPaymentLinks(links []model.MortgagePaymentLink) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, l := range links {
		if _, err := tx.Exec(
			`INSERT INTO mortgage_payment_link (transactionId, mortgageId) VALUES (?, ?)
			 ON CONFLICT(transactionId) DO UPDATE SET mortgageId=excluded.mortgageId`,
			l.TransactionID, l.MortgageID); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (d *DB) RemovePaymentLinks(mortgageID string) error {
	_, err := d.sql.Exec(`DELETE FROM mortgage_payment_link WHERE mortgageId = ?`, mortgageID)
	return err
}
func (d *DB) RemovePaymentLink(transactionID string) error {
	_, err := d.sql.Exec(`DELETE FROM mortgage_payment_link WHERE transactionId = ?`, transactionID)
	return err
}

// ---- categories ---------------------------------------------------------

func (d *DB) Categories() ([]model.SpendCategory, error) {
	rows, err := d.sql.Query(`SELECT id, name, colorHex, createdAt, isTransfer FROM category ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.SpendCategory
	for rows.Next() {
		var c model.SpendCategory
		if err := rows.Scan(&c.ID, &c.Name, &c.ColorHex, &c.CreatedAt, &c.IsTransfer); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
func (d *DB) SaveCategory(c model.SpendCategory) error {
	_, err := d.sql.Exec(
		`INSERT INTO category (id, name, colorHex, createdAt, isTransfer) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET name=excluded.name, colorHex=excluded.colorHex, createdAt=excluded.createdAt, isTransfer=excluded.isTransfer`,
		c.ID, c.Name, c.ColorHex, c.CreatedAt, c.IsTransfer)
	return err
}
func (d *DB) DeleteCategory(id string) error {
	_, err := d.sql.Exec(`DELETE FROM category WHERE id = ?`, id)
	return err
}

func (d *DB) ExpenseCategories() ([]model.ExpenseCategory, error) {
	rows, err := d.sql.Query(`SELECT id, transactionId, categoryId, startDate, endDate, isAuto, createdAt FROM expense_category`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.ExpenseCategory
	for rows.Next() {
		var e model.ExpenseCategory
		var start, end sql.NullInt64
		if err := rows.Scan(&e.ID, &e.TransactionID, &e.CategoryID, &start, &end, &e.IsAuto, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.StartDate = ptrI64(start)
		e.EndDate = ptrI64(end)
		out = append(out, e)
	}
	return out, rows.Err()
}
func (d *DB) SaveExpenseCategory(e model.ExpenseCategory) error {
	_, err := d.sql.Exec(
		`INSERT INTO expense_category (id, transactionId, categoryId, startDate, endDate, isAuto, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET transactionId=excluded.transactionId, categoryId=excluded.categoryId,
		   startDate=excluded.startDate, endDate=excluded.endDate, isAuto=excluded.isAuto, createdAt=excluded.createdAt`,
		e.ID, e.TransactionID, e.CategoryID, ni64(e.StartDate), ni64(e.EndDate), e.IsAuto, e.CreatedAt)
	return err
}
func (d *DB) DeleteExpenseCategory(id string) error {
	_, err := d.sql.Exec(`DELETE FROM expense_category WHERE id = ?`, id)
	return err
}

// ReplaceExpenseCategories atomically replaces all links for a transaction.
func (d *DB) ReplaceExpenseCategories(transactionID string, links []model.ExpenseCategory) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM expense_category WHERE transactionId = ?`, transactionID); err != nil {
		return err
	}
	for _, e := range links {
		if _, err := tx.Exec(
			`INSERT INTO expense_category (id, transactionId, categoryId, startDate, endDate, isAuto, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			e.ID, e.TransactionID, e.CategoryID, ni64(e.StartDate), ni64(e.EndDate), e.IsAuto, e.CreatedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ---- transfers ----------------------------------------------------------

func (d *DB) TransferExclusions() ([]model.TransferExclusion, error) {
	rows, err := d.sql.Query(`SELECT transactionId, createdAt FROM transfer_exclusion`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.TransferExclusion
	for rows.Next() {
		var x model.TransferExclusion
		if err := rows.Scan(&x.TransactionID, &x.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}
func (d *DB) SaveTransferExclusion(transactionID string, createdAt int64) error {
	_, err := d.sql.Exec(
		`INSERT INTO transfer_exclusion (transactionId, createdAt) VALUES (?, ?)
		 ON CONFLICT(transactionId) DO UPDATE SET createdAt=excluded.createdAt`,
		transactionID, createdAt)
	return err
}
func (d *DB) DeleteTransferExclusion(transactionID string) error {
	_, err := d.sql.Exec(`DELETE FROM transfer_exclusion WHERE transactionId = ?`, transactionID)
	return err
}
