import SwiftUI
import Charts

/// Everything about one mortgage: headline numbers, balance/equity charts, the
/// adjustments that drive them (rate changes, valuations, extra payments), and
/// the link to the real synced payment.
struct MortgageDetailView: View {
    @EnvironmentObject private var state: AppState
    let mortgage: Mortgage

    @State private var editing = false
    @State private var sheet: AdjustmentSheet?
    @State private var detected: MortgageDetection.Suggestion?
    @State private var showDetectResult = false

    private var summary: MortgageEngine.Summary { state.summary(for: mortgage) }
    private var schedule: [MortgageEngine.Point] { state.schedule(for: mortgage) }
    private var linked: [Transaction] { state.linkedTransactions(for: mortgage.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                cards
                CardSection("Home Value vs. Loan Balance", subtitle: "Projected, with your value adjustments applied") {
                    BalanceEquityChart(points: schedule)
                }
                CardSection("Equity Over Time", subtitle: "Home value minus what you owe") {
                    EquityChart(points: schedule)
                }
                adjustments
                payments
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(mortgage.name.isEmpty ? "Mortgage" : mortgage.name)
        .sheet(isPresented: $editing) {
            MortgageEditorView(draft: mortgage, isNew: false)
        }
        .sheet(item: $sheet) { which in
            AdjustmentEditor(kind: which, mortgageId: mortgage.id)
        }
        .alert("Detect payment", isPresented: $showDetectResult, presenting: detected) { s in
            Button("Link \(s.count) transactions") { state.applyDetectedPayment(s, mortgageId: mortgage.id) }
            Button("Cancel", role: .cancel) {}
        } message: { s in
            Text("Found a recurring payment to \"\(s.payee)\" near \(Format.currency(abs(s.amount))) (\(s.count) matches). Link them as this mortgage's payments?")
        }
    }

    // MARK: - Header & cards

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mortgage.name.isEmpty ? "Mortgage" : mortgage.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(Format.currency(summary.monthlyPayment))/mo · \(String(format: "%.2f", currentRate))% · payoff \(payoffText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
        }
    }

    private var currentRate: Double {
        state.rateChanges(for: mortgage.id).last(where: { $0.date <= Date() })?.annualRate ?? mortgage.annualRate
    }
    private var payoffText: String {
        guard let d = summary.payoffDate else { return "-" }
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
            MetricCard(title: "Current balance", value: Format.currency(summary.currentBalance),
                       systemImage: "creditcard", tint: Theme.expense)
            MetricCard(title: "Home value", value: Format.currency(summary.homeValue),
                       systemImage: "house", tint: Theme.accent)
            MetricCard(title: "Equity", value: Format.currency(summary.equity),
                       systemImage: "chart.line.uptrend.xyaxis", tint: Theme.income)
            MetricCard(title: "Paid off", value: String(format: "%.0f%%", summary.percentPaidOff * 100),
                       systemImage: "percent", tint: Theme.accent)
            MetricCard(title: "Interest paid", value: Format.currency(summary.interestPaidToDate),
                       systemImage: "arrow.up.right", tint: Theme.expense)
            MetricCard(title: "Lifetime interest", value: Format.currency(summary.totalInterestOverLife),
                       systemImage: "hourglass", tint: Theme.expense)
        }
    }

    // MARK: - Adjustments

    private var adjustments: some View {
        CardSection("Adjustments", subtitle: "Rates and home values are applied over time") {
            VStack(alignment: .leading, spacing: 18) {
                adjustmentGroup(
                    title: "Interest rate",
                    addLabel: "Add rate change",
                    add: { sheet = .rate },
                    rows: [("\(String(format: "%.3g", mortgage.annualRate))% from \(short(mortgage.start)) (original)", nil)]
                        + state.rateChanges(for: mortgage.id).map {
                            ("\(String(format: "%.3g", $0.annualRate))% from \(short($0.date))",
                             DeleteRef(table: MortgageRateChange.databaseTableName, id: $0.id))
                        }
                )
                Divider()
                adjustmentGroup(
                    title: "Home value",
                    addLabel: "Add valuation",
                    add: { sheet = .valuation },
                    rows: [("\(Format.currency(mortgage.purchasePrice)) at \(short(mortgage.start)) (purchase)", nil)]
                        + state.valuations(for: mortgage.id).map {
                            ("\(Format.currency($0.value)) at \(short($0.asDate))",
                             DeleteRef(table: HomeValuation.databaseTableName, id: $0.id))
                        }
                )
                Divider()
                adjustmentGroup(
                    title: "Extra principal payments",
                    addLabel: "Add extra payment",
                    add: { sheet = .manual },
                    rows: state.manualTxns(for: mortgage.id).map {
                        ("\(Format.currency($0.amount)) on \(short($0.asDate))\($0.note.map { " · \($0)" } ?? "")",
                         DeleteRef(table: MortgageManualTxn.databaseTableName, id: $0.id))
                    }
                )
            }
        }
    }

    private struct DeleteRef { let table: String; let id: String }

    @ViewBuilder
    private func adjustmentGroup(title: String, addLabel: String, add: @escaping () -> Void,
                                 rows: [(String, DeleteRef?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button(action: add) { Label(addLabel, systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
            if rows.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.callout)
                        Spacer()
                        if let ref = row.1 {
                            Button {
                                state.deleteMortgageChild(table: ref.table, id: ref.id)
                            } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Payments

    private var payments: some View {
        CardSection("Payment Tracking", subtitle: "Mark a real expense as this mortgage's payment") {
            VStack(alignment: .leading, spacing: 12) {
                if let payee = mortgage.paymentPayee, !payee.isEmpty {
                    let total = linked.reduce(0.0) { $0 + abs($1.amount) }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Linked to \"\(payee)\"").fontWeight(.semibold)
                            Text("\(linked.count) payments matched · \(Format.currency(total)) paid so far")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Text("No payment linked yet. Right-click a transaction on the Dashboard and choose \"Mark as mortgage payment\", or detect it automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        detected = state.detectPayment(for: mortgage)
                        showDetectResult = detected != nil
                    } label: { Label("Detect automatically", systemImage: "wand.and.stars") }
                    if !showDetectResult, detected == nil, mortgage.paymentPayee == nil {
                        // no-op placeholder to keep layout stable
                    }
                    Spacer()
                }
            }
        }
    }

    private func short(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }
}

// MARK: - Charts

private struct BalanceEquityChart: View {
    let points: [MortgageEngine.Point]
    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Date", p.date), y: .value("Balance", p.balance))
                    .foregroundStyle(LinearGradient(colors: [Theme.expense.opacity(0.30), Theme.expense.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Home value", p.homeValue))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(x: .value("Today", Date()))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) { Text("today").font(.caption2).foregroundStyle(.secondary) }
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.compactCurrency(d)) } } } }
        .frame(height: 240)
    }
}

private struct EquityChart: View {
    let points: [MortgageEngine.Point]
    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("Date", p.date), y: .value("Equity", max(0, p.equity)))
                .foregroundStyle(LinearGradient(colors: [Theme.income.opacity(0.45), Theme.income.opacity(0.04)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Date", p.date), y: .value("Equity", max(0, p.equity)))
                .foregroundStyle(Theme.income)
                .interpolationMethod(.monotone)
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.compactCurrency(d)) } } } }
        .frame(height: 200)
    }
}

// MARK: - Adjustment editor sheet

enum AdjustmentSheet: Identifiable {
    case rate, valuation, manual
    var id: Int { hashValue }
}

private struct AdjustmentEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let kind: AdjustmentSheet
    let mortgageId: String

    @State private var date = Date()
    @State private var number: Double = 0
    @State private var note = ""

    private var title: String {
        switch kind {
        case .rate: return "Add Rate Change"
        case .valuation: return "Add Home Valuation"
        case .manual: return "Add Extra Principal Payment"
        }
    }
    private var fieldLabel: String {
        switch kind {
        case .rate: return "New rate (%)"
        case .valuation: return "Home value"
        case .manual: return "Amount toward principal"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 24).padding(.bottom, 8)
            Form {
                DatePicker(kind == .rate ? "Effective date" : "Date", selection: $date, displayedComponents: .date)
                LabeledContent(fieldLabel) {
                    TextField("", value: $number, format: .number).multilineTextAlignment(.trailing)
                }
                if kind == .manual {
                    TextField("Note (optional)", text: $note)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(number <= 0)
            }
            .padding(16)
        }
        .frame(width: 420, height: 320)
    }

    private func save() {
        switch kind {
        case .rate: state.addRateChange(mortgageId: mortgageId, date: date, annualRate: number)
        case .valuation: state.addValuation(mortgageId: mortgageId, date: date, value: number)
        case .manual: state.addManualTxn(mortgageId: mortgageId, date: date, amount: number,
                                         note: note.isEmpty ? nil : note)
        }
    }
}
