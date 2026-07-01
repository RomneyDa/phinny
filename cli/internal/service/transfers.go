package service

import (
	"github.com/RomneyDa/phinny/cli/internal/model"
	"github.com/RomneyDa/phinny/cli/internal/transfers"
)

// MarkAsTransfer marks a transaction as a transfer (a manual link to the
// permanent Transfer category) and clears any "not a transfer" override.
func (s *Service) MarkAsTransfer(txnID string) error {
	if err := s.db.DeleteTransferExclusion(txnID); err != nil {
		return err
	}
	return s.AddManualLink(txnID, model.TransferCategoryID, nil, nil)
}

// MarkNotTransfer marks a transaction as NOT a transfer: drops any transfer
// links and records the decision so auto-detection never re-tags it.
func (s *Service) MarkNotTransfer(txnID string) error {
	snap, err := s.snapshot()
	if err != nil {
		return err
	}
	for _, l := range snap.links(txnID) {
		if l.CategoryID == model.TransferCategoryID {
			if err := s.db.DeleteExpenseCategory(l.ID); err != nil {
				return err
			}
		}
	}
	return s.db.SaveTransferExclusion(txnID, s.epoch())
}

// AutoDetectTransfers scans all transactions for transfer pairs and auto-links
// both legs to the Transfer category. Respects manual intent and "not a
// transfer" overrides. Returns the number of newly linked transactions.
func (s *Service) AutoDetectTransfers() (int, error) {
	snap, err := s.snapshot()
	if err != nil {
		return 0, err
	}
	detected := transfers.Detect(snap.Transactions, transfers.DefaultWindowDays)
	added := 0
	for id := range detected {
		if snap.TransferExclusions[id] {
			continue
		}
		existing := snap.links(id)
		if hasManual(existing) {
			continue
		}
		if hasLinkTo(existing, model.TransferCategoryID) {
			continue
		}
		if err := s.db.SaveExpenseCategory(model.ExpenseCategory{
			ID: newID(), TransactionID: id, CategoryID: model.TransferCategoryID,
			IsAuto: true, CreatedAt: s.epoch(),
		}); err != nil {
			return added, err
		}
		added++
	}
	return added, nil
}

func hasManual(links []model.ExpenseCategory) bool {
	for _, l := range links {
		if !l.IsAuto {
			return true
		}
	}
	return false
}
