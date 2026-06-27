import SwiftUI

/// Connect sheet: paste a SimpleFIN setup token to switch from demo data to a
/// real account. Presented modally from the dashboard.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                Text("Connect your account")
                    .font(.system(size: 24, weight: .bold))
                Text("Phinny is an unofficial SimpleFIN viewer. Paste a setup token to see your own income and spending.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SimpleFIN setup token").font(.headline)
                TextField("paste your token here", text: $token, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isSyncing)
                Text("Get one at simplefin.org → My Account → New SimpleFIN Setup Token. It's used once to connect; Phinny then keeps only the resulting read-only access URL in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)

            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.expense)
                    .frame(maxWidth: 440, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .disabled(state.isSyncing)
                Button {
                    Task { await state.connect(setupToken: token) }
                } label: {
                    if state.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect").frame(minWidth: 90)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isSyncing)
            }
        }
        .padding(32)
        .frame(width: 520)
    }
}
