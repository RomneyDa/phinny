import SwiftUI

/// Shared visual language for Phinny. Kept tiny and central so the dashboard
/// stays consistent and easy to restyle.
enum Theme {
    static let income = Color(red: 0.16, green: 0.73, blue: 0.51)   // emerald
    static let expense = Color(red: 0.97, green: 0.44, blue: 0.38)  // coral
    static let accent = Color(red: 0.39, green: 0.40, blue: 0.95)   // indigo
    static let cardBackground = Color(nsColor: .controlBackgroundColor)

    /// Soft gradient used behind hero numbers and the onboarding screen.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0.55, green: 0.36, blue: 0.96)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// Currency + date formatting helpers shared across views.
enum Format {
    static func currency(_ value: Double, code: String = "USD", showSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        if showSign { formatter.positivePrefix = "+" + (formatter.currencySymbol ?? "$") }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Compact currency for axis labels: $1.2k, $980, -$3.4k.
    static func compactCurrency(_ value: Double, code: String = "USD") -> String {
        let symbol = code == "USD" ? "$" : ""
        let sign = value < 0 ? "-" : ""
        let abs = Swift.abs(value)
        if abs >= 1000 {
            return "\(sign)\(symbol)\(String(format: "%.1f", abs / 1000))k"
        }
        return "\(sign)\(symbol)\(Int(abs))"
    }

    static func month(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: date)
    }

    static func mediumDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
