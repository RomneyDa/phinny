import SwiftUI

/// The obvious, visible entry point to categorizing a transaction: a small tag
/// button on each row that opens a native multi-select popover. Tap any number
/// of categories to toggle them on or off (the popover stays open), flip the
/// Transfer switch, create a category inline, or jump to the advanced sheet for
/// date-ranged links.
struct CategoryPickerButton: View {
    @EnvironmentObject private var state: AppState
    let transaction: Transaction
    /// Opens the advanced sheet (date ranges / per-window links).
    var onAdvanced: () -> Void = {}

    @State private var showing = false

    private var hasCategories: Bool { !state.appliedCategories(for: transaction).isEmpty }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: hasCategories ? "tag.fill" : "tag")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Categorize")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            CategoryMultiSelect(transaction: transaction) {
                showing = false
                onAdvanced()
            }
            .environmentObject(state)
        }
    }
}

/// The popover body: a checkbox list of every category plus transfer / create /
/// advanced controls.
private struct CategoryMultiSelect: View {
    @EnvironmentObject private var state: AppState
    let transaction: Transaction
    var onAdvanced: () -> Void

    @State private var newName = ""

    /// Normal (non-transfer) categories; Transfer gets its own toggle below.
    private var pickable: [SpendCategory] { state.categories.filter { !$0.isPermanent } }

    private var linkedIds: Set<String> {
        Set(state.links(forTransaction: transaction.id).map { $0.categoryId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Categories")
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if pickable.isEmpty {
                Text("No categories yet. Create one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(pickable) { c in
                            row(for: c)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            // Transfer has special semantics (records a "not a transfer"
            // exclusion when turned off), so it routes through its own toggle.
            Toggle(isOn: Binding(
                get: { state.isTransfer(transaction) },
                set: { $0 ? state.markAsTransfer(transaction) : state.markNotTransfer(transaction) }
            )) {
                Label("Transfer between my accounts", systemImage: "arrow.left.arrow.right")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 6) {
                TextField("New category", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Add", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Button(action: onAdvanced) {
                Label("Date ranges / advanced…", systemImage: "calendar")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private func row(for c: SpendCategory) -> some View {
        let on = linkedIds.contains(c.id)
        return Button {
            state.toggleCategory(transaction, categoryId: c.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                Circle()
                    .fill(Color(hex: c.colorHex))
                    .frame(width: 8, height: 8)
                Text(c.name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let c = state.addCategory(name: name)
        state.toggleCategory(transaction, categoryId: c.id)
        newName = ""
    }
}
