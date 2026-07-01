package service

import (
	"fmt"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// categoryPalette mirrors Theme.categoryPalette: new categories cycle through it.
var categoryPalette = []string{
	"#6366F1", "#22C55E", "#F77061", "#F5A623", "#A855F7",
	"#06B6D4", "#EC4899", "#84CC16", "#3B82F6", "#F97316",
}

func nextCategoryColor(existing int) string {
	return categoryPalette[existing%len(categoryPalette)]
}

// AddCategory creates a category (auto color if colorHex is empty).
func (s *Service) AddCategory(name, colorHex string) (model.SpendCategory, error) {
	cats, err := s.db.Categories()
	if err != nil {
		return model.SpendCategory{}, err
	}
	if colorHex == "" {
		colorHex = nextCategoryColor(len(cats))
	}
	c := model.SpendCategory{ID: newID(), Name: name, ColorHex: colorHex, CreatedAt: s.epoch()}
	if err := s.db.SaveCategory(c); err != nil {
		return model.SpendCategory{}, err
	}
	return c, nil
}

// UpdateCategory saves an edited category.
func (s *Service) UpdateCategory(c model.SpendCategory) error {
	return s.db.SaveCategory(c)
}

// DeleteCategory removes a category (cascades to its links). The permanent
// Transfer category cannot be deleted.
func (s *Service) DeleteCategory(id string) error {
	if id == model.TransferCategoryID {
		return fmt.Errorf("the Transfer category is permanent and cannot be deleted")
	}
	return s.db.DeleteCategory(id)
}

// UsageCount returns how many transactions carry at least one link to a category.
func (s *Service) UsageCount(categoryID string) (int, error) {
	links, err := s.db.ExpenseCategories()
	if err != nil {
		return 0, err
	}
	seen := map[string]bool{}
	for _, l := range links {
		if l.CategoryID == categoryID {
			seen[l.TransactionID] = true
		}
	}
	return len(seen), nil
}

// SetCategory makes categoryID the transaction's only category (empty clears
// all), applied to every similar transaction (same account + title).
func (s *Service) SetCategory(txnID string, categoryID string) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	txn, ok := findTxn(snap, txnID)
	if !ok {
		return fmt.Errorf("transaction not found: %s", txnID)
	}
	for _, t := range snap.similarTransactions(txn) {
		var links []model.ExpenseCategory
		if categoryID != "" {
			links = []model.ExpenseCategory{{
				ID: newID(), TransactionID: t.ID, CategoryID: categoryID,
				IsAuto: false, CreatedAt: s.epoch(),
			}}
		}
		if err := s.db.ReplaceExpenseCategories(t.ID, links); err != nil {
			return err
		}
	}
	return nil
}

// ToggleCategory toggles a manual link to categoryID on/off for a transaction
// and its similars, leaving links to other categories untouched.
func (s *Service) ToggleCategory(txnID, categoryID string) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	txn, ok := findTxn(snap, txnID)
	if !ok {
		return fmt.Errorf("transaction not found: %s", txnID)
	}
	turningOn := !hasLinkTo(snap.links(txn.ID), categoryID)
	for _, t := range snap.similarTransactions(txn) {
		existing := linksTo(snap.links(t.ID), categoryID)
		if turningOn {
			if len(existing) == 0 {
				if err := s.db.SaveExpenseCategory(model.ExpenseCategory{
					ID: newID(), TransactionID: t.ID, CategoryID: categoryID,
					IsAuto: false, CreatedAt: s.epoch(),
				}); err != nil {
					return err
				}
			}
		} else {
			for _, l := range existing {
				if err := s.db.DeleteExpenseCategory(l.ID); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// ClearCategories removes all links from a transaction and its similars.
func (s *Service) ClearCategories(txnID string) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	txn, ok := findTxn(snap, txnID)
	if !ok {
		// Fall back to clearing just the given id.
		return s.db.ReplaceExpenseCategories(txnID, nil)
	}
	for _, t := range snap.similarTransactions(txn) {
		if err := s.db.ReplaceExpenseCategories(t.ID, nil); err != nil {
			return err
		}
	}
	return nil
}

// AddManualLink adds a manual link (optionally windowed) to one transaction,
// replacing any conflicting link (same category, overlapping window).
func (s *Service) AddManualLink(txnID, categoryID string, start, end *int64) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	link := model.ExpenseCategory{
		ID: newID(), TransactionID: txnID, CategoryID: categoryID,
		StartDate: start, EndDate: end, IsAuto: false, CreatedAt: s.epoch(),
	}
	for _, ex := range conflicts(snap.links(txnID), link) {
		if err := s.db.DeleteExpenseCategory(ex.ID); err != nil {
			return err
		}
	}
	return s.db.SaveExpenseCategory(link)
}

// AutoAssign is the auto-categorization entry point. Respects manual intent: a
// transaction with any manual link is left untouched; otherwise the auto link
// replaces conflicting auto links.
func (s *Service) AutoAssign(txnID, categoryID string, start, end *int64) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	for _, l := range snap.links(txnID) {
		if !l.IsAuto {
			return nil // manual wins
		}
	}
	link := model.ExpenseCategory{
		ID: newID(), TransactionID: txnID, CategoryID: categoryID,
		StartDate: start, EndDate: end, IsAuto: true, CreatedAt: s.epoch(),
	}
	for _, ex := range conflicts(snap.links(txnID), link) {
		if ex.IsAuto {
			if err := s.db.DeleteExpenseCategory(ex.ID); err != nil {
				return err
			}
		}
	}
	return s.db.SaveExpenseCategory(link)
}

// RemoveLink deletes one expense-category link by id.
func (s *Service) RemoveLink(id string) error {
	return s.db.DeleteExpenseCategory(id)
}

// ---- link helpers -------------------------------------------------------

func findTxn(snap *Snapshot, id string) (model.Transaction, bool) {
	for _, t := range snap.Transactions {
		if t.ID == id {
			return t, true
		}
	}
	return model.Transaction{}, false
}

func hasLinkTo(links []model.ExpenseCategory, categoryID string) bool {
	for _, l := range links {
		if l.CategoryID == categoryID {
			return true
		}
	}
	return false
}

func linksTo(links []model.ExpenseCategory, categoryID string) []model.ExpenseCategory {
	var out []model.ExpenseCategory
	for _, l := range links {
		if l.CategoryID == categoryID {
			out = append(out, l)
		}
	}
	return out
}

// conflicts returns existing links that conflict with candidate: same category,
// overlapping window (the only conflict the model recognizes).
func conflicts(links []model.ExpenseCategory, candidate model.ExpenseCategory) []model.ExpenseCategory {
	var out []model.ExpenseCategory
	for _, l := range links {
		if l.ID != candidate.ID && l.CategoryID == candidate.CategoryID && model.WindowsOverlap(l, candidate) {
			out = append(out, l)
		}
	}
	return out
}
