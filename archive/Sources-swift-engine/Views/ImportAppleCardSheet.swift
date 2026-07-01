import SwiftUI
import UniformTypeIdentifiers

/// Explains how to obtain an Apple Card statement (Apple blocks aggregators, so
/// it can never be synced) and launches the file picker. The actual file dialog
/// lives here rather than on the dashboard so the instructions always come first.
struct ImportAppleCardSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let importTypes: [UTType]

    @State private var showingImporter = false

    private let steps = [
        "On your iPhone, open the Wallet app and tap Apple Card.",
        "Tap Card Balance, then open the monthly statement you want.",
        "Tap Export Transactions and choose a format (CSV, OFX, QFX, or QBO).",
        "Save or AirDrop the file to this Mac, then choose it below.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "creditcard")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                Text("Import Apple Card Statement")
                    .font(.title3.bold())
            }

            Text("Apple blocks aggregators (Plaid, MX, SimpleFIN) from Apple Card, so it cannot be synced. Instead, export a statement from your iPhone and import the file here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 20)
                            .background(Theme.accent.opacity(0.14), in: Circle())
                        Text(step)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Re-importing the same statement is safe: existing transactions are updated, not duplicated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    showingImporter = true
                } label: {
                    Label("Choose File…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await state.importStatement(from: url) }
                    dismiss()
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }
}
