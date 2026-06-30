import SwiftUI

/// Manage the SimpleFIN connection and accounts: see what the access URL
/// returns, hide accounts you do not want on the dashboard, connect/disconnect,
/// and jump to the SimpleFIN Bridge to add or relink banks (SimpleFIN has no API
/// for adding accounts, so that step happens on the bridge website).
struct SimpleFINView: View {
    @EnvironmentObject private var state: AppState
    @State private var showDisconnect = false

    /// The SimpleFIN Bridge: where you connect banks and mint setup tokens.
    private let bridgeURL = URL(string: "https://bridge.simplefin.org")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SimpleFIN")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brandGradient)
                    Text("Manage your connection and choose which accounts appear on the dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                connectionCard
                accountsCard
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Connection

    private var connectionCard: some View {
        CardSection("Connection") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(state.isConnected ? Theme.income : Color.secondary)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.isConnected ? "Connected" : "Not connected")
                            .font(.subheadline).fontWeight(.semibold)
                        Text(statusDetail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isConnected {
                        Button("Disconnect…", role: .destructive) { showDisconnect = true }
                            .confirmationDialog(
                                "Disconnect from SimpleFIN?",
                                isPresented: $showDisconnect
                            ) {
                                Button("Disconnect", role: .destructive) {
                                    Task { await state.disconnect() }
                                }
                            } message: {
                                Text("Phinny will forget your access URL. Your locally stored data stays, but it will not sync until you reconnect.")
                            }
                    } else {
                        Button("Connect Account") {
                            state.errorMessage = nil
                            state.showingConnectSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add or relink banks")
                            .font(.subheadline).fontWeight(.semibold)
                        Text("Connect your banks and create a setup token on the SimpleFIN Bridge, then paste it here to sync them in.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Link(destination: bridgeURL) {
                        Label("Open SimpleFIN Bridge", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var statusDetail: String {
        if state.isConnected {
            if state.isSyncing { return "Syncing now…" }
            if let last = state.lastSync { return "Last synced \(Format.relative(last)). Sync from the dashboard." }
            return "Sync from the dashboard to pull your latest data."
        }
        if state.isImportOnly { return "Showing imported Apple Card data only. Connect to sync bank accounts." }
        return "Connect a SimpleFIN account to see your own income and spending."
    }

    // MARK: - Accounts

    private var accountsCard: some View {
        CardSection("Accounts", subtitle: accountsSubtitle) {
            if state.accounts.isEmpty {
                Text(state.isConnected
                     ? "No accounts returned yet. Try Sync Now on the dashboard."
                     : "Connect an account to list it here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.accounts) { account in
                        AccountRow(account: account)
                        if account.id != state.accounts.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var accountsSubtitle: String {
        let total = state.accounts.count
        guard total > 0 else { return "Hidden accounts are left out of dashboard totals" }
        let hidden = state.hiddenAccountIds.count
        if hidden == 0 { return "Hide an account to leave it out of dashboard totals" }
        return "\(hidden) of \(total) hidden from the dashboard"
    }

}

/// One account row: org + name, balance, and a show/hide toggle. Hidden accounts
/// are dimmed and badged so it is clear they are excluded from the dashboard.
private struct AccountRow: View {
    @EnvironmentObject private var state: AppState
    let account: Account

    private var isHidden: Bool { account.hidden }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name.isEmpty ? "Account" : account.name)
                        .fontWeight(.medium)
                    if isHidden {
                        Text("Hidden")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                if !account.orgName.isEmpty {
                    Text(account.orgName)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(Format.currency(account.balance, code: account.currency))
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)

            Button {
                state.setAccountHidden(account.id, hidden: !isHidden)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(isHidden ? Color.secondary : Theme.accent)
            }
            .buttonStyle(.borderless)
            .help(isHidden ? "Show on the dashboard" : "Hide from the dashboard")
        }
        .padding(.vertical, 9)
        .opacity(isHidden ? 0.55 : 1)
    }
}
