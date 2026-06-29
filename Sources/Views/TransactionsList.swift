import SwiftUI

/// The recent-transactions table. Renders the full history but only materializes
/// a window of rows at a time, widening it by `batchSize` as the last row scrolls
/// into view (infinite scroll). The whole transaction set already lives in
/// `AppState` (analytics needs it), so this pages over that in-memory array
/// rather than re-querying SQLite, which keeps a single source of truth.
struct TransactionsList: View {
    @EnvironmentObject private var state: AppState
    let transactions: [Transaction]
    let accountsById: [String: String]
    let currency: String
    var batchSize: Int = 50

    @State private var categorizing: Transaction?
    @State private var detailing: Transaction?
    @State private var visibleCount: Int = 50

    private var visible: [Transaction] {
        Array(transactions.prefix(visibleCount))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, txn in
                row(txn)
                    .onAppear { loadMore(reachedIndex: index) }
                if index != visible.count - 1 { Divider() }
            }

            if transactions.isEmpty {
                Text("No transactions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                footer
            }
        }
        .sheet(item: $categorizing) { txn in
            AssignCategorySheet(transaction: txn)
        }
        .sheet(item: $detailing) { txn in
            TransactionDetailSheet(transaction: txn, accountsById: accountsById, currency: currency)
        }
    }

    /// One transaction row: direction badge, description + category chips, account
    /// and date, signed amount, plus the category / mortgage context menu.
    @ViewBuilder
    private func row(_ txn: Transaction) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill((txn.isIncome ? Theme.income : Theme.expense).opacity(0.15))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: txn.isIncome ? "arrow.down" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(txn.isIncome ? Theme.income : Theme.expense)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(txn.groupLabel)
                        .font(.body)
                        .lineLimit(1)
                    ForEach(state.appliedCategories(for: txn)) { c in
                        CategoryChip(category: c)
                    }
                    if let m = state.mortgage(forPayment: txn) {
                        MortgageChip(name: m.name.isEmpty ? "Mortgage" : m.name)
                    }
                    CategoryPickerButton(transaction: txn) { categorizing = txn }
                }
                HStack(spacing: 6) {
                    Text(accountsById[txn.accountId] ?? "Account")
                    Text("·")
                    Text(Format.mediumDate(txn.date))
                    if txn.pending {
                        Text("· pending").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Format.currency(txn.amount, code: currency, showSign: true))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(txn.isIncome ? Theme.income : .primary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { detailing = txn }
        .contextMenu {
            Menu("Category") {
                CategoryPickerMenu(transaction: txn) { categorizing = txn }
            }
            Menu("Mortgage payment") {
                MortgagePaymentMenu(transaction: txn)
            }
        }
    }

    /// A subtle "showing X of Y" footer; doubles as the scroll target that pulls
    /// in the next batch on slow/instant scrolls.
    @ViewBuilder
    private var footer: some View {
        if visibleCount < transactions.count {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Showing \(visibleCount) of \(transactions.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .onAppear { loadMore(reachedIndex: visibleCount - 1) }
        } else if transactions.count > batchSize {
            Text("All \(transactions.count) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    /// Widen the window when a row near the end becomes visible.
    private func loadMore(reachedIndex index: Int) {
        guard visibleCount < transactions.count else { return }
        if index >= visibleCount - 1 {
            visibleCount = min(visibleCount + batchSize, transactions.count)
        }
    }
}
