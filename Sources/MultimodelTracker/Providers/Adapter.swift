import Foundation

struct FetchedUsage {
    let plan: String?
    let limits: [UsageLimit]
    /// OpenAI's banked limit-reset count. Kept as a number as well as in the
    /// row label, because the "banked reset added" alert needs to compare it
    /// against the previous refresh — parsing it back out of a label would
    /// break the moment the wording changed.
    var bankedResets: Int?

    init(plan: String?, limits: [UsageLimit], bankedResets: Int? = nil) {
        self.plan = plan; self.limits = limits; self.bankedResets = bankedResets
    }
}

enum AdapterError: Error, CustomStringConvertible {
    case notSignedIn, blocked(String), transport(String), notImplemented(String)
    var description: String {
        switch self {
        case .notSignedIn:            return "Not signed in"
        case .blocked(let s):         return "Blocked: \(s)"
        case .transport(let s):       return s
        case .notImplemented(let s):  return "\(s) not wired yet"
        }
    }
}

protocol UsageAdapter {
    func fetch(account: Account) async throws -> FetchedUsage
}

enum ProviderRegistry {
    static func adapter(for p: Provider) -> UsageAdapter {
        switch p {
        case .openai:    return OpenAIAdapter()
        case .anthropic: return AnthropicAdapter()
        case .google:    return GoogleAdapterImpl()
        }
    }
}

/// OpenAI is the straightforward one: a plain HTTPS GET carrying a bearer
/// token plus the account id header. No browser engine required — verified
/// against the live endpoint.
struct OpenAIAdapter: UsageAdapter {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(account: Account) async throws -> FetchedUsage {
        guard let creds = try? await Keychain.openAICredentialsAsync(for: account.id) else {
            throw AdapterError.notSignedIn
        }
        do {
            return try await fetchOnce(creds)
        } catch AdapterError.notSignedIn {
            // Renew, cheapest route first. A refresh token (browser OAuth)
            // needs no browser and no cookies; the cookie-jar re-mint is the
            // fallback for accounts signed in through the old web window.
            if let refresh = creds.refreshToken,
               let renewed = try? await OpenAIOAuth.refresh(refresh) {
                Keychain.storeOpenAI(accessToken: renewed.accessToken,
                                     accountId: renewed.accountID ?? creds.accountId,
                                     refreshToken: renewed.refreshToken, for: account.id)
                let fresh = try await Keychain.openAICredentialsAsync(for: account.id)
                return try await fetchOnce(fresh)
            }
            guard let session = try? await WebSessionPool.shared.openAIWebSession(for: account) ?? nil
            else { throw AdapterError.notSignedIn }
            Keychain.storeOpenAI(accessToken: session.accessToken,
                                 accountId: session.accountId, for: account.id)
            let renewed = try await Keychain.openAICredentialsAsync(for: account.id)
            return try await fetchOnce(renewed)
        }
    }

    private func fetchOnce(_ creds: Keychain.OpenAICreds) async throws -> FetchedUsage {
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let acct = creds.accountId {
            req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue(Support.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AdapterError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AdapterError.notSignedIn }
        guard http.statusCode == 200 else { throw AdapterError.transport("HTTP \(http.statusCode)") }
        return try OpenAIParser.parse(data)
    }
}

/// Anthropic needs a real browser context — claude.ai sits behind Cloudflare,
/// which rejects plain URLSession fingerprints. Each account gets its own
/// WKWebView data store so several subscriptions can be signed in at once.
/// (Verified: WebKit clears the Cloudflare check and reaches the real API.)
struct AnthropicAdapter: UsageAdapter {
    func fetch(account: Account) async throws -> FetchedUsage {
        try await WebSessionPool.shared.fetchUsage(for: account)
    }
}
