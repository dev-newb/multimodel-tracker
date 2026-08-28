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

/// Anthropic, OAuth first: accounts signed in through the browser hold an
/// api.anthropic.com bearer token, and that host's usage endpoint answers a
/// plain URLSession — no Cloudflare, no browser engine. It returns the same
/// limits[] payload as claude.ai's own usage endpoint, so the parser is
/// shared. Accounts from the old embedded-window flow have no token and fall
/// through to their per-account claude.ai cookie jar, which still needs
/// WebKit to pass Cloudflare.
struct AnthropicAdapter: UsageAdapter {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(account: Account) async throws -> FetchedUsage {
        guard let creds = try? await Keychain.anthropicCredentialsAsync(for: account.id) else {
            return try await WebSessionPool.shared.fetchUsage(for: account)
        }
        // Refresh ahead of a known expiry rather than spending a doomed
        // round trip; the expiry is stored precisely so this test is local.
        var live = creds
        if let exp = creds.expiresAt, exp <= Date().addingTimeInterval(120) {
            live = try await refreshed(creds, account: account.id)
        }
        do {
            return try await fetchOnce(live.accessToken)
        } catch AdapterError.notSignedIn {
            // The token died early (revocation, clock skew) — one refresh,
            // one retry, then give up to the "Sign in" button.
            let renewed = try await refreshed(live, account: account.id)
            return try await fetchOnce(renewed.accessToken)
        }
    }

    private func refreshed(_ creds: Keychain.AnthropicCreds,
                           account: UUID) async throws -> Keychain.AnthropicCreds {
        guard let rt = creds.refreshToken,
              let t = try? await AnthropicOAuth.refresh(rt) else {
            throw AdapterError.notSignedIn
        }
        Keychain.storeAnthropic(accessToken: t.accessToken,
                                refreshToken: t.refreshToken ?? rt,
                                expiresAt: t.expiresAt, for: account)
        return try await Keychain.anthropicCredentialsAsync(for: account)
    }

    private func fetchOnce(_ token: String) async throws -> FetchedUsage {
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AdapterError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AdapterError.notSignedIn }
        guard http.statusCode == 200 else { throw AdapterError.transport("HTTP \(http.statusCode)") }
        return try AnthropicParser.parse(data)
    }
}
