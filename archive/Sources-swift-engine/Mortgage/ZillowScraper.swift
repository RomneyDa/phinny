import Foundation
import WebKit
import AppKit

enum ZillowError: LocalizedError {
    case noAddress
    case blocked
    case notFound
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAddress:
            return "Add a property address to this mortgage first."
        case .blocked:
            return "Zillow showed a bot check and couldn't be read automatically. Try again in a little while."
        case .notFound:
            return "Couldn't find a Zestimate for that address on Zillow."
        case .loadFailed(let m):
            return "Zillow page failed to load: \(m)"
        }
    }
}

/// Fetches a Zillow "Zestimate" for an address by loading the page in an
/// offscreen WKWebView (a real browser engine), letting it run Zillow's
/// JavaScript like Safari would, then reading the value out of the DOM. This is
/// far more reliable than a plain HTTP request, which Zillow blocks outright.
///
/// Manual trigger only. Best-effort: if Zillow serves a human bot-check, this
/// reports `.blocked` rather than trying to defeat it.
@MainActor
final class ZillowScraper: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// `input` is either a full Zillow property URL (preferred, most reliable) or
    /// a plain address (best-effort search).
    func fetchZestimate(address input: String) async throws -> Double {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZillowError.noAddress }
        let url: URL
        if trimmed.lowercased().hasPrefix("http"), let u = URL(string: trimmed) {
            url = u
        } else if let u = searchURL(for: trimmed) {
            url = u
        } else {
            throw ZillowError.noAddress
        }

        // Ephemeral data store so each lookup is independent (no cached page,
        // cookies, or "recently viewed" Zestimate bleeding across addresses).
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1400), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        wv.navigationDelegate = self
        // Host offscreen (alpha 0) in a real window so WebKit fully renders.
        if let host = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
            wv.alphaValue = 0
            host.addSubview(wv)
        }
        webView = wv
        defer {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.removeFromSuperview()
            webView = nil
        }

        // Establish a session on the homepage first so the address URL resolves
        // to the actual property (a cold request gets a generic metro page).
        if let home = URL(string: "https://www.zillow.com/") {
            try? await withTimeout(seconds: 25) { try await self.load(URLRequest(url: home)) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            return r
        }()
        try await withTimeout(seconds: 30) { [request] in try await self.load(request) }

        lastURL = ((try? await wv.evaluateJavaScript("document.location.href")) as? String) ?? ""
        lastTitle = ((try? await wv.evaluateJavaScript("document.title")) as? String) ?? ""

        // The Zestimate can render after the initial load; poll a few times.
        for _ in 0..<8 {
            if let value = try await extractZestimate() { return value }
            if try await looksBlocked() { throw ZillowError.blocked }
            try await Task.sleep(nanoseconds: 1_600_000_000)
        }
        if try await looksBlocked() { throw ZillowError.blocked }
        throw ZillowError.notFound
    }

    private func searchURL(for address: String) -> URL? {
        // Zillow's canonical address slug: commas dropped, spaces -> dashes.
        // e.g. "742 Maple St, Portland, OR 97205" -> "742-Maple-St-Portland-OR-97205".
        let slug = address
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: "-")
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "https://www.zillow.com/homes/\(encoded)_rb/")
    }

    /// Diagnostic: the final URL + page title after the lookup (for dev probing).
    private(set) var lastURL = ""
    private(set) var lastTitle = ""

    // MARK: - Navigation

    private func load(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            webView?.load(request)
        }
    }

    private func resumeLoad(_ result: Result<Void, Error>) {
        loadContinuation?.resume(with: result)
        loadContinuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in resumeLoad(.success(())) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumeLoad(.failure(ZillowError.loadFailed(error.localizedDescription))) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumeLoad(.failure(ZillowError.loadFailed(error.localizedDescription))) }
    }

    // MARK: - Extraction

    private func extractZestimate() async throws -> Double? {
        let js = #"""
        (function () {
          var html = document.documentElement.innerHTML;
          var patterns = [
            /"zestimate":\s*\{\s*"?amount"?\s*:\s*([0-9]{5,})/i,
            /"zestimate"\s*:\s*([0-9]{5,})/i,
            /\\"zestimate\\":\s*\{\\?"?value\\?"?:\s*([0-9]{5,})/i
          ];
          for (var i = 0; i < patterns.length; i++) {
            var m = html.match(patterns[i]);
            if (m) return parseInt(m[1]);
          }
          var text = document.body ? document.body.innerText : "";
          var t = text.match(/zestimate[^0-9$]{0,40}\$\s*([0-9][0-9,]{4,})/i);
          if (t) return parseInt(t[1].replace(/,/g, ""));
          return null;
        })();
        """#
        let result = try await webView?.evaluateJavaScript(js)
        if let n = result as? Double { return n > 0 ? n : nil }
        if let n = result as? Int { return n > 0 ? Double(n) : nil }
        if let s = result as? String, let n = Double(s), n > 0 { return n }
        return nil
    }

    private func looksBlocked() async throws -> Bool {
        let js = "(document.body ? document.body.innerText.slice(0, 4000) : '')"
        let text = ((try? await webView?.evaluateJavaScript(js)) as? String ?? "").lowercased()
        return text.contains("press & hold") || text.contains("press and hold")
            || text.contains("captcha") || text.contains("are you a human")
            || text.contains("verify you are")
    }
}

/// Run `op`, failing with a timeout error if it takes longer than `seconds`.
private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ZillowError.loadFailed("timed out")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
