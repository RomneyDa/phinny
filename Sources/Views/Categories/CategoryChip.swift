import SwiftUI

/// A small colored pill showing a category name. Used on transaction rows and
/// in the category manager.
struct CategoryChip: View {
    let category: SpendCategory
    var auto: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: category.colorHex))
                .frame(width: 7, height: 7)
            Text(category.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if auto {
                Image(systemName: "sparkles")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(hex: category.colorHex).opacity(0.14), in: Capsule())
    }
}

/// The list of "set category" buttons shared by the row context menu and the
/// transactions table. Sets a single manual category (replacing existing links).
struct CategoryPickerMenu: View {
    @EnvironmentObject private var state: AppState
    let transaction: Transaction
    var onAdvanced: () -> Void = {}

    private var current: Set<String> {
        Set(state.links(forTransaction: transaction.id).map { $0.categoryId })
    }

    var body: some View {
        ForEach(state.categories) { c in
            Button {
                state.setCategory(transaction, categoryId: c.id)
            } label: {
                if current.contains(c.id) {
                    Label(c.name, systemImage: "checkmark")
                } else {
                    Text(c.name)
                }
            }
        }
        if state.categories.isEmpty {
            Text("No categories yet")
        }
        Divider()
        Button("With date range / multiple…", action: onAdvanced)
        if !current.isEmpty {
            Button("Clear category", role: .destructive) {
                state.clearCategories(transactionId: transaction.id)
            }
        }
    }
}
