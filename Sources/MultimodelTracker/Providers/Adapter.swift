import Foundation

struct FetchedUsage { let plan: String?; let limits: [UsageLimit] }

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
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let acct = creds.accountId {
            req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue(Support.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AdapterError.transport("no response") }
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
