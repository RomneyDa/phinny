import SwiftUI
import UniformTypeIdentifiers

/// The main screen: summary cards, charts, and recent transactions. Shown in
/// both demo and connected modes (a banner marks demo mode).
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImporter = false

    private var accountsById: [String: String] {
        Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.name) })
    }

    /// File types the statement importer accepts. OFX/QFX/QBO have no standard
    /// UTType, so we resolve them by extension and fall back to `.data` (the
    /// parser validates the actual content).
    private var importTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText]
        for ext in ["ofx", "qfx", "qbo"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        types.append(.data)
        return types
    }

    private let importHelp =
        "Export a closed monthly statement from the iPhone Wallet app (Apple Card > Card Balance > a statement > Export Transactions) as CSV, OFX, QFX, or QBO, then import it here."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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

                if let msg = state.importMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.income)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.income.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await state.importStatement(from: url) }
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            if state.isDemo {
                importButton(prominent: false)
                Button {
                    state.errorMessage = nil
                    state.showingConnectSheet = true
                } label: {
                    Label("Connect Account", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            } else if state.isImportOnly {
                // Apple Card imports, no SimpleFIN account: nothing to sync.
                importButton(prominent: true)
                Menu {
                    Button("Connect SimpleFIN Account…") {
                        state.errorMessage = nil
                        state.showingConnectSheet = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                    Button {
                        state.errorMessage = nil
                        showingImporter = true
                    } label: {
                        Label("Import Apple Card Statement…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button("Disconnect…", role: .destructive) { Task { await state.disconnect() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// "Import Apple Card" button used in demo and import-only modes.
    @ViewBuilder
    private func importButton(prominent: Bool) -> some View {
        let action = {
            state.errorMessage = nil
            showingImporter = true
        }
        let label = Label("Import Apple Card…", systemImage: "square.and.arrow.down")
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .help(importHelp)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .help(importHelp)
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
