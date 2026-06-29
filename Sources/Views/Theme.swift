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

    /// Palette new categories cycle through (indigo, emerald, coral, amber, etc.).
    static let categoryPalette = [
        "#6366F1", "#22C55E", "#F77061", "#F5A623", "#A855F7",
        "#06B6D4", "#EC4899", "#84CC16", "#3B82F6", "#F97316",
    ]

    /// Pick the next palette color given how many categories already exist.
    static func nextCategoryColor(existing: Int) -> String {
        categoryPalette[existing % categoryPalette.count]
    }
}

extension Color {
    /// Parse a "#RRGGBB" (or "RRGGBB") hex string. Falls back to gray.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&rgb) else {
            self = .gray
            return
        }
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
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
