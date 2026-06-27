import SwiftUI

/// The main screen: summary cards, charts, and recent transactions. Shown in
/// both demo and connected modes (a banner marks demo mode).
struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    private var accountsById: [String: String] {
        Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.name) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if state.isDemo { demoBanner }

                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.expense)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.expense.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                SummaryCards(summary: state.summary, currency: state.primaryCurrency)

                CardSection("Income vs. Spending", subtitle: "Last 12 months") {
                    IncomeExpenseChart(flows: state.monthlyFlows, currency: state.primaryCurrency)
                }

                HStack(alignment: .top, spacing: 18) {
                    CardSection("Net Cash Flow", subtitle: "Income minus spending, per month") {
                        CashflowChart(flows: state.monthlyFlows, currency: state.primaryCurrency)
                    }
                    CardSection("Top Spending", subtitle: "Last 30 days") {
                        CategoryChart(spending: state.topSpending, currency: state.primaryCurrency)
                    }
                }

                CardSection("Recent Transactions") {
                    TransactionsList(
                        transactions: state.transactions,
                        accountsById: accountsById,
                        currency: state.primaryCurrency
                    )
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phinny")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if state.isDemo {
                Button {
                    state.errorMessage = nil
                    state.showingConnectSheet = true
                } label: {
                    Label("Connect Account", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await state.sync(force: true) }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(state.isSyncing)

                if state.isSyncing {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }

                Menu {
                    Button("Disconnect…", role: .destructive) { state.disconnect() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var demoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("You're viewing demo data").font(.subheadline).fontWeight(.semibold)
                Text("Connect a SimpleFIN account to see your own income and spending.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") {
                state.errorMessage = nil
                state.showingConnectSheet = true
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
    }

    private var subtitle: String {
        let accounts = state.accounts.count
        let txns = state.transactions.count
        let base = "\(accounts) account\(accounts == 1 ? "" : "s") · \(txns) transactions"
        if state.isDemo { return "Demo · " + base }
        if state.isSyncing { return base + " · syncing…" }
        if let last = state.lastSync { return base + " · synced \(Format.relative(last))" }
        return base
    }
}
