import SwiftUI

/// Advanced categorization for one transaction: assign a category with an
/// optional effective date range, create a new category inline, and see/remove
/// the links already attached. This is where the model's full flexibility (date
/// ranges, multiple categories per expense) is exposed.
struct AssignCategorySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction

    @State private var selectedCategoryId: String = ""
    @State private var useRange = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var newName = ""

    private var links: [ExpenseCategory] { state.links(forTransaction: transaction.id) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Categorize")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 2)
            Text(transaction.groupLabel + "  ·  " + Format.currency(transaction.amount, showSign: true))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            Form {
                if !links.isEmpty {
                    Section("Current categories") {
                        ForEach(links) { link in
                            HStack {
                                if let c = state.categoriesById[link.categoryId] {
                                    CategoryChip(category: c, auto: link.isAuto)
                                } else {
                                    Text("(deleted category)").foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let label = windowLabel(link) {
                                    Text(label).font(.caption).foregroundStyle(.secondary)
                                }
                                Button {
                                    state.removeLink(link.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Add a category") {
                    Picker("Category", selection: $selectedCategoryId) {
                        Text("Select…").tag("")
                        ForEach(state.categories) { c in Text(c.name).tag(c.id) }
                    }
                    Toggle("Only for a date range", isOn: $useRange)
                    if useRange {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("To", selection: $end, displayedComponents: .date)
                    }
                    Button("Add") {
                        state.addManualLink(
                            transactionId: transaction.id, categoryId: selectedCategoryId,
                            start: useRange ? start : nil, end: useRange ? end : nil)
                        selectedCategoryId = ""
                        useRange = false
                    }
                    .disabled(selectedCategoryId.isEmpty)
                }

                Section("New category") {
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("Groceries"))
                        Button("Create") {
                            let c = state.addCategory(name: newName.trimmingCharacters(in: .whitespaces))
                            newName = ""
                            selectedCategoryId = c.id
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    private func windowLabel(_ link: ExpenseCategory) -> String? {
        guard link.hasWindow else { return nil }
        let f: (Date) -> String = { Format.mediumDate($0) }
        switch (link.startDateValue, link.endDateValue) {
        case let (s?, e?): return "\(f(s)) - \(f(e))"
        case let (s?, nil): return "from \(f(s))"
        case let (nil, e?): return "until \(f(e))"
        default: return nil
        }
    }
}
