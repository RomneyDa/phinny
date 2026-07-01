// Package store is Phinny's SQLite persistence layer. It is the Go equivalent of
// the Swift AppDatabase: it opens ~/.phinny/phinny.sqlite, runs the schema
// migrations, and exposes typed reads/writes.
//
// Interop note: the database is shared with (and was historically created by)
// the GRDB-backed Swift app, which records applied migrations in a
// `grdb_migrations(identifier)` table. This package uses the SAME table and the
// SAME migration identifiers (v1..v9) so it never double-applies a migration on
// an existing database, and any database it creates is readable by GRDB.
//
// Concurrency: WAL mode + a busy timeout let the long-running daemon and one-off
// CLI invocations safely share the file (concurrent readers, one writer).
package store

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

// DB wraps the SQLite handle.
type DB struct {
	sql *sql.DB
}

// Open opens (creating if needed) the database at path and runs migrations.
func Open(path string) (*DB, error) {
	// modernc.org/sqlite takes pragmas as query params via the DSN.
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)", path)
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection keeps WAL + foreign_keys pragmas effective and avoids
	// "database is locked" churn from the pure-Go driver under our light load.
	sqlDB.SetMaxOpenConns(1)
	db := &DB{sql: sqlDB}
	if err := db.migrate(); err != nil {
		sqlDB.Close()
		return nil, err
	}
	return db, nil
}

// OpenMemory opens a private in-memory database (tests).
func OpenMemory() (*DB, error) {
	sqlDB, err := sql.Open("sqlite", "file::memory:?_pragma=foreign_keys(ON)")
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(1)
	db := &DB{sql: sqlDB}
	if err := db.migrate(); err != nil {
		sqlDB.Close()
		return nil, err
	}
	return db, nil
}

func (d *DB) Close() error { return d.sql.Close() }

// migration is one GRDB-compatible migration: an identifier plus the SQL run
// inside a transaction when it has not been applied yet.
type migration struct {
	id  string
	sql string
}

// migrations mirrors AppDatabase.migrator (Database.swift) verbatim. Append new
// migrations; never edit an applied one.
var migrations = []migration{
	{"v1", `
		CREATE TABLE account (
			id TEXT PRIMARY KEY NOT NULL,
			name TEXT NOT NULL,
			orgName TEXT NOT NULL,
			currency TEXT NOT NULL,
			balance DOUBLE NOT NULL,
			availableBalance DOUBLE,
			balanceDate INTEGER
		);
		CREATE TABLE transaction_row (
			id TEXT PRIMARY KEY NOT NULL,
			providerId TEXT NOT NULL,
			accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
			posted INTEGER NOT NULL,
			amount DOUBLE NOT NULL,
			descriptionText TEXT NOT NULL,
			payee TEXT,
			memo TEXT,
			category TEXT,
			pending BOOLEAN NOT NULL
		);
		CREATE INDEX index_transaction_row_on_accountId ON transaction_row(accountId);
		CREATE INDEX index_transaction_row_on_posted ON transaction_row(posted);
		CREATE TABLE meta (
			key TEXT PRIMARY KEY NOT NULL,
			value TEXT NOT NULL
		);`},
	{"v2", `
		CREATE TABLE mortgage (
			id TEXT PRIMARY KEY NOT NULL,
			name TEXT NOT NULL,
			principal DOUBLE NOT NULL,
			downKind TEXT NOT NULL,
			downValue DOUBLE NOT NULL,
			annualRate DOUBLE NOT NULL,
			termMonths INTEGER NOT NULL,
			startDate INTEGER NOT NULL,
			paymentPayee TEXT,
			paymentAmount DOUBLE,
			createdAt INTEGER NOT NULL
		);
		CREATE TABLE mortgage_rate_change (
			id TEXT PRIMARY KEY NOT NULL,
			mortgageId TEXT NOT NULL REFERENCES mortgage(id) ON DELETE CASCADE,
			effectiveDate INTEGER NOT NULL,
			annualRate DOUBLE NOT NULL
		);
		CREATE INDEX index_mortgage_rate_change_on_mortgageId ON mortgage_rate_change(mortgageId);
		CREATE TABLE home_valuation (
			id TEXT PRIMARY KEY NOT NULL,
			mortgageId TEXT NOT NULL REFERENCES mortgage(id) ON DELETE CASCADE,
			date INTEGER NOT NULL,
			value DOUBLE NOT NULL
		);
		CREATE INDEX index_home_valuation_on_mortgageId ON home_valuation(mortgageId);
		CREATE TABLE mortgage_manual_txn (
			id TEXT PRIMARY KEY NOT NULL,
			mortgageId TEXT NOT NULL REFERENCES mortgage(id) ON DELETE CASCADE,
			date INTEGER NOT NULL,
			amount DOUBLE NOT NULL,
			note TEXT
		);
		CREATE INDEX index_mortgage_manual_txn_on_mortgageId ON mortgage_manual_txn(mortgageId);
		CREATE TABLE mortgage_payment_link (
			transactionId TEXT PRIMARY KEY NOT NULL,
			mortgageId TEXT NOT NULL REFERENCES mortgage(id) ON DELETE CASCADE
		);
		CREATE INDEX index_mortgage_payment_link_on_mortgageId ON mortgage_payment_link(mortgageId);`},
	{"v3", `
		ALTER TABLE mortgage ADD COLUMN address TEXT;
		ALTER TABLE home_valuation ADD COLUMN source TEXT;`},
	{"v4", `
		ALTER TABLE mortgage ADD COLUMN zillowUrl TEXT;`},
	{"v5", `
		CREATE TABLE category (
			id TEXT PRIMARY KEY NOT NULL,
			name TEXT NOT NULL,
			colorHex TEXT NOT NULL,
			createdAt INTEGER NOT NULL
		);
		CREATE TABLE expense_category (
			id TEXT PRIMARY KEY NOT NULL,
			transactionId TEXT NOT NULL,
			categoryId TEXT NOT NULL REFERENCES category(id) ON DELETE CASCADE,
			startDate INTEGER,
			endDate INTEGER,
			isAuto BOOLEAN NOT NULL,
			createdAt INTEGER NOT NULL
		);
		CREATE INDEX index_expense_category_on_transactionId ON expense_category(transactionId);
		CREATE INDEX index_expense_category_on_categoryId ON expense_category(categoryId);`},
	{"v6", `
		ALTER TABLE category ADD COLUMN isTransfer BOOLEAN NOT NULL DEFAULT 0;
		INSERT INTO category (id, name, colorHex, createdAt, isTransfer) VALUES ('transfer', 'Transfer', '#64748B', 0, 1);
		CREATE TABLE transfer_exclusion (
			transactionId TEXT PRIMARY KEY NOT NULL,
			createdAt INTEGER NOT NULL
		);`},
	{"v7", `
		ALTER TABLE mortgage ADD COLUMN paymentAccountId TEXT;`},
	{"v8", `
		CREATE TABLE account_hidden (
			accountId TEXT PRIMARY KEY NOT NULL,
			createdAt INTEGER NOT NULL
		);`},
	{"v9", `
		ALTER TABLE account ADD COLUMN hidden BOOLEAN NOT NULL DEFAULT 0;
		UPDATE account SET hidden = 1 WHERE id IN (SELECT accountId FROM account_hidden);
		DROP TABLE account_hidden;`},
}

func (d *DB) migrate() error {
	if _, err := d.sql.Exec(
		`CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)`,
	); err != nil {
		return fmt.Errorf("create grdb_migrations: %w", err)
	}

	applied := map[string]bool{}
	rows, err := d.sql.Query(`SELECT identifier FROM grdb_migrations`)
	if err != nil {
		return fmt.Errorf("read grdb_migrations: %w", err)
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		applied[id] = true
	}
	rows.Close()

	for _, m := range migrations {
		if applied[m.id] {
			continue
		}
		tx, err := d.sql.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(m.sql); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", m.id, err)
		}
		if _, err := tx.Exec(`INSERT INTO grdb_migrations (identifier) VALUES (?)`, m.id); err != nil {
			tx.Rollback()
			return fmt.Errorf("record migration %s: %w", m.id, err)
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
