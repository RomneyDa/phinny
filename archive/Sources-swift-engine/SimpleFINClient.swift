import Foundation

/// Minimal SimpleFIN protocol client. Two operations:
///
/// 1. `claim(setupToken:)` - exchanges a single-use setup token for a permanent
///    access URL (with embedded read-only credentials). Run ONCE per token.
/// 2. `fetchAccounts(accessURL:since:)` - pulls accounts + transactions. This is
///    the rate-limited call (the provider allows ~24/day), so callers guard it.
///
/// Spec: https://www.simplefin.org/protocol.html
enum SimpleFINClient {

    enum SimpleFINError: LocalizedError {
        case badSetupToken
        case claimFailed(status: Int)
        case badAccessURL
        case requestFailed(status: Int)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .badSetupToken:
                return "That doesn't look like a valid SimpleFIN setup token."
            case .claimFailed(let status):
                return "Claiming the setup token failed (HTTP \(status)). Tokens are single-use - you may need a fresh one."
            case .badAccessURL:
                return "The stored SimpleFIN access URL is malformed."
            case .requestFailed(let status):
                return "SimpleFIN request failed (HTTP \(status))."
            case .decodeFailed(let detail):
                return "Could not read the SimpleFIN response: \(detail)"
            }
        }
    }

    // MARK: - Claim

    /// Exchange a base64 setup token for a permanent access URL.
    static func claim(setupToken raw: String) async throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let claimURL = decodeClaimURL(token) else {
            throw SimpleFINError.badSetupToken
        }

        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SimpleFINError.claimFailed(status: status)
        }
        let accessURL = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard accessURL.hasPrefix("http") else {
            throw SimpleFINError.claimFailed(status: status)
        }
        return accessURL
    }

    private static func decodeClaimURL(_ token: String) -> URL? {
        // Base64 may arrive without padding; restore it before decoding.
        var b64 = token
        let remainder = b64.count % 4
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: b64),
              let urlString = String(data: data, encoding: .utf8),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Fetch

    /// Result of a fetch, already mapped to Phinny's storage models.
    struct FetchResult {
        var accounts: [Account]
        var transactions: [Transaction]
    }

    /// Pull accounts + transactions posted since `since`. RATE-LIMITED - guard callers.
    static func fetchAccounts(accessURL: String, since: Date) async throws -> FetchResult {
        guard var components = URLComponents(string: accessURL) else {
            throw SimpleFINError.badAccessURL
        }

        // SimpleFIN embeds basic-auth credentials in the URL userinfo. URLSession
        // won't use them automatically, so pull them out and send an explicit
        // Authorization header against the credential-free URL.
        let username = components.user
        let password = components.password
        components.user = nil
        components.password = nil

        guard let base = components.url else { throw SimpleFINError.badAccessURL }
        var accountsComponents = URLComponents(
            url: base.appendingPathComponent("accounts"), resolvingAgainstBaseURL: false
        )
        accountsComponents?.queryItems = [
            URLQueryItem(name: "start-date", value: String(Int(since.timeIntervalSince1970))),
            URLQueryItem(name: "pending", value: "1"),
        ]
        guard let url = accountsComponents?.url else { throw SimpleFINError.badAccessURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let username {
            let creds = "\(username):\(password ?? "")"
            let encoded = Data(creds.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SimpleFINError.requestFailed(status: status)
        }

        do {
            let payload = try JSONDecoder().decode(SetResponse.self, from: data)
            return map(payload)
        } catch {
            throw SimpleFINError.decodeFailed(String(describing: error))
        }
    }

    // MARK: - Wire format → storage models

    private static func map(_ payload: SetResponse) -> FetchResult {
        var accounts: [Account] = []
        var transactions: [Transaction] = []
        for raw in payload.accounts {
            accounts.append(Account(
                id: raw.id,
                name: raw.name,
                orgName: raw.org?.name ?? raw.org?.domain ?? "",
                currency: raw.currency ?? "USD",
                balance: Double(raw.balance ?? "") ?? 0,
                availableBalance: raw.availableBalance.flatMap { Double($0) },
                balanceDate: raw.balanceDate
            ))
            for t in raw.transactions ?? [] {
                // SimpleFIN leaves `posted` at 0 for pending transactions and
                // supplies `transacted_at` instead. Fall back to it so pending
                // items sort and display with the right date.
                let effectivePosted = t.posted != 0 ? t.posted : (t.transactedAt ?? t.posted)
                transactions.append(Transaction(
                    id: "\(raw.id)|\(t.id)",
                    providerId: t.id,
                    accountId: raw.id,
                    posted: effectivePosted,
                    amount: Double(t.amount) ?? 0,
                    descriptionText: t.description ?? "",
                    payee: t.payee,
                    memo: t.memo,
                    category: t.extra?["category"]?.value as? String,
                    pending: t.pending ?? false
                ))
            }
        }
        return FetchResult(accounts: accounts, transactions: transactions)
    }

    // MARK: - SimpleFIN wire format (amounts are decimal strings)

    private struct SetResponse: Decodable {
        let accounts: [RawAccount]
    }

    private struct RawAccount: Decodable {
        let id: String
        let name: String
        let currency: String?
        let balance: String?
        let availableBalance: String?
        let balanceDate: Int?
        let org: RawOrg?
        let transactions: [RawTransaction]?

        enum CodingKeys: String, CodingKey {
            case id, name, currency, balance, org, transactions
            case availableBalance = "available-balance"
            case balanceDate = "balance-date"
        }
    }

    private struct RawOrg: Decodable {
        let name: String?
        let domain: String?
    }

    private struct RawTransaction: Decodable {
        let id: String
        let posted: Int
        let transactedAt: Int?
        let amount: String
        let description: String?
        let payee: String?
        let memo: String?
        let pending: Bool?
        let extra: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
            case id, posted, amount, description, payee, memo, pending, extra
            case transactedAt = "transacted_at"
        }
    }
}

/// Tiny type-erased decodable so we can read optional `extra` fields (like a
/// bridge-provided category) without modeling every possible key.
struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = "" }
    }
}
