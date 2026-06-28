import SwiftUI

/// Add or edit a mortgage. Captures just the facts; the schedule is computed.
struct MortgageEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    var onSaved: (Mortgage) -> Void = { _ in }

    @State private var name: String
    @State private var address: String
    @State private var principal: Double
    @State private var downKind: Mortgage.DownKind
    @State private var downValue: Double
    @State private var annualRate: Double
    @State private var termYears: Int
    @State private var startDate: Date
    @StateObject private var completer = AddressCompleter()
    @FocusState private var addressFocused: Bool

    private let original: Mortgage

    init(draft: Mortgage, isNew: Bool, onSaved: @escaping (Mortgage) -> Void = { _ in }) {
        self.isNew = isNew
        self.onSaved = onSaved
        self.original = draft
        _name = State(initialValue: draft.name)
        _address = State(initialValue: draft.address ?? "")
        _principal = State(initialValue: draft.principal)
        _downKind = State(initialValue: draft.down)
        _downValue = State(initialValue: draft.downValue)
        _annualRate = State(initialValue: draft.annualRate)
        _termYears = State(initialValue: max(1, draft.termMonths / 12))
        _startDate = State(initialValue: draft.start)
    }

    /// Live preview built from the current field values.
    private var preview: Mortgage {
        var m = original
        m.name = name; m.principal = principal
        m.address = address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address
        m.downKind = downKind.rawValue; m.downValue = downValue
        m.annualRate = annualRate; m.termMonths = termYears * 12
        m.startDate = Int(startDate.timeIntervalSince1970)
        return m
    }

    private var monthlyPayment: Double {
        MortgageEngine.payment(principal: principal, monthlyRate: annualRate / 100 / 12, months: termYears * 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Mortgage" : "Edit Mortgage")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Maple Street House"))
                    LabeledContent("Address") {
                        TextField("123 Main St, City, ST", text: $address)
                            .multilineTextAlignment(.trailing)
                            .focused($addressFocused)
                            .onChange(of: address) { _, new in completer.update(new) }
                    }
                    if addressFocused && !completer.suggestions.isEmpty {
                        ForEach(completer.suggestions.prefix(4)) { s in
                            Button {
                                address = s.full
                                completer.accept()
                                addressFocused = false
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title)
                                    if !s.subtitle.isEmpty {
                                        Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    LabeledContent("Mortgage amount") {
                        TextField("Loan amount", value: $principal, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Down payment") {
                        HStack {
                            Picker("", selection: $downKind) {
                                Text("%").tag(Mortgage.DownKind.percent)
                                Text("$").tag(Mortgage.DownKind.amount)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 90)
                            TextField("Down", value: $downValue, format: .number)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Interest rate (%)") {
                        TextField("Rate", value: $annualRate, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Term (years)") {
                        TextField("Years", value: $termYears, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }

                Section("Computed") {
                    LabeledContent("Purchase price", value: Format.currency(preview.purchasePrice))
                    LabeledContent("Down payment", value: Format.currency(preview.downAmount))
                    LabeledContent("Monthly payment (P&I)", value: Format.currency(monthlyPayment))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        state.deleteMortgage(original.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let saved = state.upsertMortgage(preview)
                    onSaved(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || principal <= 0)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }
}
