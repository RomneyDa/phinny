import SwiftUI
import Charts

/// Grouped monthly income vs. spending bars.
struct IncomeExpenseChart: View {
    let flows: [Analytics.MonthlyFlow]
    let currency: String

    private struct Bar: Identifiable {
        let id = UUID()
        let month: Date
        let kind: String
        let amount: Double
    }

    private var bars: [Bar] {
        flows.flatMap { flow in
            [Bar(month: flow.month, kind: "Income", amount: flow.income),
             Bar(month: flow.month, kind: "Spending", amount: flow.expense)]
        }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Month", bar.month, unit: .month),
                y: .value("Amount", bar.amount)
            )
            .foregroundStyle(by: .value("Type", bar.kind))
            .position(by: .value("Type", bar.kind))
            .cornerRadius(4)
        }
        .chartForegroundStyleScale(["Income": Theme.income, "Spending": Theme.expense])
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Format.compactCurrency(amount, code: currency))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 240)
    }
}

/// Net cash flow per month as an area + line, colored by sign.
struct CashflowChart: View {
    let flows: [Analytics.MonthlyFlow]
    let currency: String

    var body: some View {
        Chart(flows) { flow in
            AreaMark(
                x: .value("Month", flow.month, unit: .month),
                y: .value("Net", flow.net)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Month", flow.month, unit: .month),
                y: .value("Net", flow.net)
            )
            .foregroundStyle(Theme.accent)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.5))

            PointMark(
                x: .value("Month", flow.month, unit: .month),
                y: .value("Net", flow.net)
            )
            .foregroundStyle(flow.net >= 0 ? Theme.income : Theme.expense)
            .symbolSize(50)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Format.compactCurrency(amount, code: currency))
                    }
                }
            }
        }
        .frame(height: 240)
    }
}

/// Horizontal bars of the top spending groups (last 30 days).
struct CategoryChart: View {
    let spending: [Analytics.CategorySpend]
    let currency: String

    var body: some View {
        if spending.isEmpty {
            Text("No spending in the last 30 days.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 240, alignment: .center)
                .frame(maxWidth: .infinity)
        } else {
            Chart(spending) { item in
                BarMark(
                    x: .value("Amount", item.amount),
                    y: .value("Group", item.label)
                )
                .foregroundStyle(Theme.brandGradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(Format.compactCurrency(item.amount, code: currency))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Format.compactCurrency(amount, code: currency))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: max(180, CGFloat(spending.count) * 34))
        }
    }
}
