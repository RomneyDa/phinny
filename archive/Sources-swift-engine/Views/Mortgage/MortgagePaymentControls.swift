import SwiftUI

/// Menu items for linking a transaction to a mortgage as its recurring payment.
/// Shared by the visible row button and the row context menu so both behave the
/// same. Marking one payment auto-links every other expense on the same account
/// with the same title.
struct MortgagePaymentMenu: View {
    @EnvironmentObject private var state: AppState
    let transaction: Transaction

    private var linkedMortgageId: String? { state.mortgage(forPayment: transaction)?.id }

    var body: some View {
        if state.mortgages.isEmpty {
            Text("Add a mortgage to link payments")
        } else {
            ForEach(state.mortgages) { m in
                let linked = linkedMortgageId == m.id
                Button {
                    if linked { state.unlinkPayment(transaction) }
                    else { state.markAsPayment(transaction, mortgageId: m.id) }
                } label: {
                    if linked {
                        Label("\(name(m)) payment", systemImage: "checkmark")
                    } else {
                        Text("Mark as \(name(m)) payment")
                    }
                }
            }
            if linkedMortgageId != nil {
                Divider()
                Button("Remove mortgage link", role: .destructive) {
                    state.unlinkPayment(transaction)
                }
            }
        }
    }

    private func name(_ m: Mortgage) -> String { m.name.isEmpty ? "Mortgage" : m.name }
}

/// A small badge marking a transaction as a linked mortgage payment, styled like
/// a category chip so linked rows read at a glance (and so auto-detected matches
/// are visibly tagged too).
struct MortgageChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "house.fill")
                .font(.system(size: 7))
            Text(name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.accent.opacity(0.14), in: Capsule())
    }
}
