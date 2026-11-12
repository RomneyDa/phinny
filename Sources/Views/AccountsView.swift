import SwiftUI

/// Per-account balances, and the transactions behind whichever account is
/// selected. The dashboard answers "what do I have in total"; this answers
/// "where is it, and what moved in this one account".
///
/// Rollups come from the engine's `dashboard` payload so the parts always add
/// up to the headline cards; the transaction rows are filtered client-side from
/// the set `AppState` already holds.
struct AccountsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedAccountId: String?

    private var accountsById: [String: String] {
        Dictionary(uniqueKeysWithValues: state.visibleAccounts.map { ($0.id, $0.name) })
    }

    /// The rollup the detail pane is showing, defaulting to the largest
    /// balance (rollups arrive sorted) so the pane is never empty.
    private var selected: Analytics.AccountRollup? {
        if let id = selectedAccountId,
           let match = state.accountRollups.first(where: { $0.accountId == id }) {
            return match
        }
        return state.accountRollups.first
    }

    private var selectedTransactions: [Transaction] {
        guard let selected else { return [] }
        return state.visibleTransactions.filter { $0.accountId == selected.accountId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if state.accountRollups.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "building.columns",
                        description: Text("Connect SimpleFIN or import a statement to see your accounts.")
                    )
                    .frame(minHeight: 320)
                } else {
                    CardSection("Accounts", subtitle: subtitleText) {
                        VStack(spacing: 8) {
                            ForEach(state.accountRollups) { rollup in
                                AccountRow(
                                    rollup: rollup,
                                    isSelected: rollup.accountId == selected?.accountId,
                                    currency: state.primaryCurrency
                                ) {
                                    selectedAccountId = rollup.accountId
                                }
                            }
                        }
                    }

                    if let selected {
                        CardSection(
                            selected.name.isEmpty ? "Transactions" : selected.name,
                            subtitle: detailSubtitle(for: selected, showing: selectedTransactions.count)
                        ) {
                            TransactionsList(
                                transactions: selectedTransactions,
                                accountsById: accountsById,
                                currency: selected.currency.isEmpty
                                    ? state.primaryCurrency
                                    : selected.currency
                            )
                        }
                    }
                }
            }
            .padding(20)
            .scrollKeyboardNavigation()
        }
        .navigationTitle("Accounts")
    }

    private var subtitleText: String {
        let count = state.accountRollups.count
        let noun = count == 1 ? "account" : "accounts"
        return "\(count) \(noun), totalling \(Format.currency(state.summary.totalBalance, code: state.primaryCurrency))"
    }

    /// Counts the rows actually listed, which includes transfers (they keep
    /// their chip here, as on the dashboard). The rollup's own count excludes
    /// them, since it has to add up to the summary, so using it here would
    /// label the list with a smaller number than it shows.
    private func detailSubtitle(for rollup: Analytics.AccountRollup, showing count: Int) -> String {
        let noun = count == 1 ? "transaction" : "transactions"
        return "\(rollup.orgName), \(count) \(noun)"
    }
}

/// One tappable account line: balance on the right, this month's flow under it.
private struct AccountRow: View {
    let rollup: Analytics.AccountRollup
    let isSelected: Bool
    let currency: String
    let onSelect: () -> Void

    private var code: String { rollup.currency.isEmpty ? currency : rollup.currency }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rollup.name.isEmpty ? "Account" : rollup.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(rollup.orgName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    // A negative balance is debt (credit cards), so tint it.
                    Text(Format.currency(rollup.balance, code: code))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(rollup.balance < 0 ? Theme.expense : .primary)
                        .lineLimit(1)
                    Text("\(Format.currency(rollup.currentMonthNet, code: code, showSign: true)) this month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected
                            ? Theme.accent.opacity(0.5)
                            : Color(nsColor: .separatorColor).opacity(0.8),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
