import SwiftUI
import MapKit

/// A single address suggestion (Sendable, so it can cross the completer's
/// delegate callback into the main actor without data-race warnings).
struct AddressSuggestion: Identifiable, Hashable {
    let title: String
    let subtitle: String
    var id: String { title + "|" + subtitle }
    var full: String { [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ") }
}

/// Native address autocomplete backed by MapKit's local search completer
/// (no API key needed). Publishes address suggestions as the query changes.
@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [AddressSuggestion] = []
    private let completer = MKLocalSearchCompleter()
    private var suppressNext = false

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func update(_ query: String) {
        if suppressNext { suppressNext = false; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; return }
        completer.queryFragment = q
    }

    /// Call when the user picks a suggestion so the next text change doesn't reopen the list.
    func accept() {
        suppressNext = true
        suggestions = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.map { AddressSuggestion(title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor in self.suggestions = mapped }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
