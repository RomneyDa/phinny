import SwiftUI

/// Manage spending categories: create, rename, recolor, delete. Categories are
/// global and shared by every transaction. The same records are what a future AI
/// auto-categorizer reads and writes.
struct CategoriesView: View {
    @EnvironmentObject private var state: AppState
    @State private var newName = ""
    @State private var transferMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Categories")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brandGradient)
                    Text("Group your spending. Assign categories to transactions from the dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                CardSection("Add a category") {
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("Groceries, Travel, Subscriptions…"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(create)
                        Button("Add", action: create)
                            .buttonStyle(.borderedProminent)
                            .disabled(trimmedName.isEmpty)
                    }
                }

                CardSection("Transfers") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find money moved between your own accounts and tag it as a transfer so it does not count as income or spending.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let transferMessage {
                                Text(transferMessage)
                                    .font(.caption).foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer()
                        Button("Detect transfers") {
                            Task {
                                let n = await state.autoDetectTransfers()
                                transferMessage = n == 0
                                    ? "No new transfers found."
                                    : "Tagged \(n) transaction\(n == 1 ? "" : "s") as transfers."
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                CardSection("Your categories") {
                    if state.categories.isEmpty {
                        Text("No categories yet. Add one above.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(state.categories) { c in
                                CategoryRow(category: c)
                                if c.id != state.categories.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }
    private func create() {
        guard !trimmedName.isEmpty else { return }
        state.addCategory(name: trimmedName)
        newName = ""
    }
}

/// One editable category row: color swatch, inline-rename name, usage count, delete.
private struct CategoryRow: View {
    @EnvironmentObject private var state: AppState
    let category: SpendCategory

    @State private var name: String
    @State private var showDelete = false

    init(category: SpendCategory) {
        self.category = category
        _name = State(initialValue: category.name)
    }

    private var usage: Int { state.usageCount(categoryId: category.id) }

    var body: some View {
        HStack(spacing: 12) {
            ColorMenu(category: category)

            if category.isPermanent {
                Text(category.name)
                Text("excluded from totals")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            } else {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit(commitName)
            }

            Spacer()

            Text("\(usage) txn\(usage == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            if !category.isPermanent {
                Button {
                    showDelete = true
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Delete \"\(category.name)\"?", isPresented: $showDelete) {
                    Button("Delete category", role: .destructive) { state.deleteCategory(category.id) }
                } message: {
                    Text(usage == 0
                         ? "This category has no transactions."
                         : "This will remove it from \(usage) transaction\(usage == 1 ? "" : "s").")
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != category.name else { return }
        var c = category; c.name = trimmed
        state.updateCategory(c)
    }
}

/// A swatch that opens a small palette to recolor the category.
private struct ColorMenu: View {
    @EnvironmentObject private var state: AppState
    let category: SpendCategory

    var body: some View {
        Menu {
            ForEach(Theme.categoryPalette, id: \.self) { hex in
                Button {
                    var c = category; c.colorHex = hex
                    state.updateCategory(c)
                } label: {
                    Label(hex, systemImage: category.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Circle()
                .fill(Color(hex: category.colorHex))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.separator, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
