import SwiftUI
import Charts

/// An editable home-value timeline. Double-click anywhere to add a valuation
/// where you clicked, drag a point to move it (the whole mortgage view updates
/// live), or click a point to edit its exact value/date or delete it.
struct InteractiveHomeValueChart: View {
    @EnvironmentObject private var state: AppState
    let mortgage: Mortgage

    @State private var draggingId: String?
    @State private var editing: HomeValuation?

    private var valuations: [HomeValuation] { state.valuations(for: mortgage.id) }

    private var domainStart: Date { mortgage.start }
    private var domainEnd: Date {
        let last = valuations.map(\.asDate).max() ?? Date()
        let end = max(Date(), last)
        return Calendar.current.date(byAdding: .month, value: 4, to: end) ?? end
    }
    private var maxValue: Double {
        let vmax = valuations.map(\.value).max() ?? 0
        return max(mortgage.purchasePrice, vmax) * 1.3
    }

    /// Step-line points: purchase price at the start, then each valuation, held
    /// flat to the end of the visible range.
    private var linePoints: [(date: Date, value: Double)] {
        var pts: [(Date, Double)] = [(domainStart, mortgage.purchasePrice)]
        pts += valuations.map { ($0.asDate, $0.value) }
        pts.sort { $0.0 < $1.0 }
        if let last = pts.last { pts.append((domainEnd, last.1)) }
        return pts.map { (date: $0.0, value: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            Text("Double-click to add a point · drag a point to adjust · click a point to edit")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { v in EditValuationSheet(valuation: v) }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(linePoints.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(Array(linePoints.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            PointMark(x: .value("Date", domainStart), y: .value("Value", mortgage.purchasePrice))
                .foregroundStyle(.secondary)
                .symbolSize(55)
                .annotation(position: .bottom) { Text("purchase").font(.caption2).foregroundStyle(.secondary) }
            ForEach(valuations) { v in
                PointMark(x: .value("Date", v.asDate), y: .value("Value", v.value))
                    .foregroundStyle(draggingId == v.id ? Theme.income : (v.isAutomated ? Color.orange : Theme.accent))
                    .symbolSize(draggingId == v.id ? 230 : 140)
            }
            RuleMark(x: .value("Today", Date()))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: 0...maxValue)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Format.compactCurrency(d)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(drag(proxy, geo))
                    .gesture(ExclusiveGesture(
                        SpatialTapGesture(count: 2).onEnded { handleDoubleTap($0.location, proxy, geo) },
                        SpatialTapGesture(count: 1).onEnded { handleSingleTap($0.location, proxy, geo) }
                    ))
            }
        }
        .frame(height: 260)
    }

    // MARK: - Gestures

    private func drag(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                if draggingId == nil {
                    draggingId = nearestValuation(to: g.startLocation, proxy, geo)?.id
                }
                guard let id = draggingId, let (date, value) = data(at: g.location, proxy, geo) else { return }
                state.setLiveValuation(HomeValuation(
                    id: id, mortgageId: mortgage.id,
                    date: Int(clamp(date).timeIntervalSince1970), value: round1000(value)))
            }
            .onEnded { _ in
                if let live = state.liveValuation { state.commitValuation(live) }
                draggingId = nil
            }
    }

    private func handleDoubleTap(_ loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) {
        guard let (date, value) = data(at: loc, proxy, geo) else { return }
        state.addValuation(mortgageId: mortgage.id, date: clamp(date), value: round1000(value))
    }

    private func handleSingleTap(_ loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) {
        if let v = nearestValuation(to: loc, proxy, geo) { editing = v }
    }

    // MARK: - Coordinate helpers

    private func plotRect(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect? {
        guard let anchor = proxy.plotFrame else { return nil }
        return geo[anchor]
    }

    private func data(at location: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> (Date, Double)? {
        guard let rect = plotRect(proxy, geo) else { return nil }
        guard let date = proxy.value(atX: location.x - rect.minX, as: Date.self),
              let value = proxy.value(atY: location.y - rect.minY, as: Double.self) else { return nil }
        return (date, value)
    }

    private func nearestValuation(to location: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> HomeValuation? {
        guard let rect = plotRect(proxy, geo) else { return nil }
        var best: HomeValuation?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for v in valuations {
            guard let px = proxy.position(forX: v.asDate), let py = proxy.position(forY: v.value) else { continue }
            let d = hypot(px + rect.minX - location.x, py + rect.minY - location.y)
            if d < bestDistance { bestDistance = d; best = v }
        }
        return bestDistance <= 24 ? best : nil
    }

    private func clamp(_ d: Date) -> Date { min(max(d, domainStart), Date()) }
    private func round1000(_ v: Double) -> Double { (max(0, v) / 1000).rounded() * 1000 }
}

/// Edit the exact value/date of a valuation, or delete it.
private struct EditValuationSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let valuation: HomeValuation
    @State private var date: Date
    @State private var value: Double

    init(valuation: HomeValuation) {
        self.valuation = valuation
        _date = State(initialValue: valuation.asDate)
        _value = State(initialValue: valuation.value)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Valuation").font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 24).padding(.bottom, 8)
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                LabeledContent("Home value") {
                    TextField("", value: $value, format: .number).multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    state.deleteMortgageChild(table: HomeValuation.databaseTableName, id: valuation.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    state.updateValuation(HomeValuation(
                        id: valuation.id, mortgageId: valuation.mortgageId,
                        date: Int(date.timeIntervalSince1970), value: value))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value <= 0)
            }
            .padding(16)
        }
        .frame(width: 380, height: 280)
    }
}
