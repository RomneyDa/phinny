import SwiftUI

/// A compact recent-transactions table.
struct TransactionsList: View {
    @EnvironmentObject private var state: AppState
    let transactions: [Transaction]
    let accountsById: [String: String]
    let currency: String
    var limit: Int = 12

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(transactions.prefix(limit))) { txn in
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
                        Text(txn.groupLabel)
                            .font(.body)
                            .lineLimit(1)
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
                .contextMenu {
                    if state.mortgages.isEmpty {
                        Text("Add a mortgage to link payments")
                    } else {
                        Menu("Mark as mortgage payment") {
                            ForEach(state.mortgages) { m in
                                Button(m.name.isEmpty ? "Mortgage" : m.name) {
                                    state.markAsPayment(txn, mortgageId: m.id)
                                }
                            }
                        }
                    }
                }

                if txn.id != transactions.prefix(limit).last?.id {
                    Divider()
                }
            }
            if transactions.isEmpty {
                Text("No transactions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
        }
    }
}
