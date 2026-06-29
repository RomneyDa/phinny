import SwiftUI

/// Opens when a transaction row is clicked. Shows the transaction, every similar
/// transaction (same account + title), and an inconspicuous control to link the
/// group to a mortgage as its recurring payment.
struct TransactionDetailSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    let accountsById: [String: String]
    let currency: String

    private var similar: [Transaction] { state.similarTransactions(to: transaction) }
    private var linkedMortgage: Mortgage? { state.mortgage(forPayment: transaction) }
    private var accountName: String { accountsById[transaction.accountId] ?? "Account" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            similarSection
            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill((transaction.isIncome ? Theme.income : Theme.expense).opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: transaction.isIncome ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(transaction.isIncome ? Theme.income : Theme.expense)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.groupLabel)
                        .font(.headline)
                        .lineLimit(1)
                    ForEach(state.appliedCategories(for: transaction)) { c in
                        CategoryChip(category: c)
                    }
                    if let m = linkedMortgage {
                        MortgageChip(name: m.name.isEmpty ? "Mortgage" : m.name)
                    }
                }
                Text(accountName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.currency(transaction.amount, code: currency, showSign: true))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(transaction.isIncome ? Theme.income : .primary)
                Text(Format.mediumDate(transaction.date))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(similar.count) similar \(similar.count == 1 ? "transaction" : "transactions")")
                .font(.subheadline.weight(.semibold))
            Text("Same account and title.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(similar) { t in
                        HStack {
                            Text(Format.mediumDate(t.date))
                                .font(.callout)
                            if t.id == transaction.id {
                                Text("this one")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            Spacer()
                            Text(Format.currency(t.amount, code: currency, showSign: true))
                                .font(.system(.callout, design: .rounded))
                                .foregroundStyle(t.isIncome ? Theme.income : .primary)
                        }
                        .padding(.vertical, 7)
                        if t.id != similar.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            mortgageControl
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    /// Deliberately understated: a small text menu, not a prominent button.
    @ViewBuilder
    private var mortgageControl: some View {
        if let m = linkedMortgage {
            HStack(spacing: 8) {
                Text("Linked to \(m.name.isEmpty ? "mortgage" : m.name)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Unlink") { state.unlinkPayment(transaction) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else if !state.mortgages.isEmpty {
            Menu {
                ForEach(state.mortgages) { m in
                    Button("Mark as \(m.name.isEmpty ? "Mortgage" : m.name) payment") {
                        state.markAsPayment(transaction, mortgageId: m.id)
                    }
                }
            } label: {
                Label("Link to mortgage payment", systemImage: "house")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }
}
