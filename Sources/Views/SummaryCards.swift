import SwiftUI

/// The row of headline metric cards at the top of the dashboard.
struct SummaryCards: View {
    let summary: Analytics.Summary
    let currency: String

    var body: some View {
        // Always a single row: four equal-width cards (each is maxWidth .infinity).
        HStack(spacing: 12) {
            MetricCard(
                title: "Total balance",
                value: Format.currency(summary.totalBalance, code: currency),
                systemImage: "banknote",
                tint: Theme.accent
            )
            MetricCard(
                title: "Income this month",
                value: Format.currency(summary.currentMonthIncome, code: currency),
                systemImage: "arrow.down.circle.fill",
                tint: Theme.income
            )
            MetricCard(
                title: "Spending this month",
                value: Format.currency(summary.currentMonthExpense, code: currency),
                systemImage: "arrow.up.circle.fill",
                tint: Theme.expense
            )
            MetricCard(
                title: "Net this month",
                value: Format.currency(summary.currentMonthNet, code: currency, showSign: true),
                systemImage: "equal.circle.fill",
                tint: summary.currentMonthNet >= 0 ? Theme.income : Theme.expense
            )
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
}

/// Reusable titled container for the charts.
struct CardSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
}
