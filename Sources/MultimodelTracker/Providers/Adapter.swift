import Foundation

struct FetchedUsage {
    var plan: String?
    let limits: [UsageLimit]
    /// OpenAI's banked limit-reset count. Kept as a number as well as in the
    /// row label, because the "banked reset added" alert needs to compare it
    /// against the previous refresh — parsing it back out of a label would
    /// break the moment the wording changed.
    var bankedResets: Int?
    /// Whose account the provider says this is, when it says.
    var accountEmail: String?
    /// How these credentials were obtained, re-derived on every refresh.
    var authSource: AuthSource?

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
        let creds = try await Keychain.openAICredentialsAsync(for: account.id)
        do {
            var out = try await fetchOnce(creds)
            // A Codex CLI import holds no refresh token by design; a browser
            // sign-in always has one. That is the honest signal for where
            // these credentials came from.
            out.authSource = creds.refreshToken == nil ? .codexCLI : .browser
            return out
        } catch AdapterError.notSignedIn {
            // Renew, cheapest route first. A refresh token (browser OAuth)
            // needs no browser and no cookies; the cookie-jar re-mint is the
            // fallback for accounts signed in through the old web window.
            if let refresh = creds.refreshToken,
               let renewed = try? await OpenAIOAuth.refresh(refresh) {
                try await Keychain.storeOpenAI(accessToken: renewed.accessToken,
                                     accountId: renewed.accountID ?? creds.accountId,
                                     refreshToken: renewed.refreshToken, for: account.id)
                let fresh = try await Keychain.openAICredentialsAsync(for: account.id)
                return try await fetchOnce(fresh)
            }
            guard let session = try? await WebSessionPool.shared.openAIWebSession(for: account) ?? nil
            else { throw AdapterError.notSignedIn }
            try await Keychain.storeOpenAI(accessToken: session.accessToken,
                                 accountId: session.accountId, for: account.id)
            let renewed = try await Keychain.openAICredentialsAsync(for: account.id)
            var out = try await fetchOnce(renewed)
            out.authSource = renewed.refreshToken == nil ? .codexCLI : .browser
            return out
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
        let creds: Keychain.AnthropicCreds
        do { creds = try await Keychain.anthropicCredentialsAsync(for: account.id) }
        catch AdapterError.notSignedIn {
            // No stored token at all: this is a legacy cookie-jar login.
            var out = try await WebSessionPool.shared.fetchUsage(for: account)
            out.authSource = .legacyCookies
            return out
        }
        // The Claude Code import deliberately never takes a refresh token
        // (consuming the CLI's rotating one could end its session), so its
        // absence is what marks an account as read from the CLI.
        let source: AuthSource = creds.refreshToken == nil ? .claudeCode : .browser
        // Refresh ahead of a known expiry rather than spending a doomed
        // round trip; the expiry is stored precisely so this test is local.
        var live = creds
        if let exp = creds.expiresAt, exp <= Date().addingTimeInterval(120) {
            live = try await refreshed(creds, account: account.id)
        }
        do {
            var out = await withEmail(try await fetchOnce(live.accessToken), token: live.accessToken, account: account)
            out.authSource = source
            return out
        } catch AdapterError.notSignedIn {
            // The token died early (revocation, clock skew) — one refresh,
            // one retry, then give up to the "Sign in" button.
            let renewed = try await refreshed(live, account: account.id)
            var out = await withEmail(try await fetchOnce(renewed.accessToken), token: renewed.accessToken, account: account)
            out.authSource = source
            return out
        }
    }

    /// Adds the token owner's email while the row still shows a placeholder
    /// (a Claude Code import says "Claude Code"; a fresh browser sign-in may
    /// not have returned one). One extra request, only until the label sticks.
    private func withEmail(_ usage: FetchedUsage, token: String, account: Account) async -> FetchedUsage {
        guard !account.label.contains("@") else { return usage }
        var out = usage
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let acct = obj["account"] as? [String: Any]
            out.accountEmail = (acct?["email_address"] as? String) ?? (acct?["email"] as? String)
                ?? (obj["email"] as? String)
        }
        return out
    }

    private func refreshed(_ creds: Keychain.AnthropicCreds,
                           account: UUID) async throws -> Keychain.AnthropicCreds {
        guard let rt = creds.refreshToken,
              let t = try? await AnthropicOAuth.refresh(rt) else {
            throw AdapterError.notSignedIn
        }
        try await Keychain.storeAnthropic(accessToken: t.accessToken,
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
