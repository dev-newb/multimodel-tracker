import WebKit

/// One hidden WKWebView per Anthropic account, each with its OWN data store,
/// so four claude.ai subscriptions can be signed in simultaneously — a single
/// shared cookie jar is what limits the Electron app to one.
///
/// A browser engine is required rather than URLSession: claude.ai is behind
/// Cloudflare, which rejects plain HTTP client fingerprints. WebKit passes —
/// verified: an empty jar reaches the real API and gets Anthropic's own
/// account_session_invalid JSON rather than a challenge page.
@MainActor
final class WebSessionPool {
    static let shared = WebSessionPool()
    private var views: [UUID: WKWebView] = [:]

    private func view(for account: Account) -> WKWebView {
        if let v = views[account.id] { return v }
        let cfg = WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            // Persistent AND isolated: survives relaunch, never shares cookies.
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
        } else {
            cfg.websiteDataStore = .nonPersistent()
        }
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Support.chromeUserAgent
        views[account.id] = v
        return v
    }

    /// Presents the claude.ai login inside this account's isolated store.
    func signInView(for account: Account) -> WKWebView {
        let v = view(for: account)
        v.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return v
    }

    /// The organisations this account can see. Empty (or a throw) means the
    /// cookie jar has no valid session — which is also how sign-in completion
    /// is detected.
    func organizations(for account: Account) async throws -> [(id: String, name: String)] {
        let v = view(for: account)
        if v.url == nil {
            v.load(URLRequest(url: URL(string: "https://claude.ai/")!))
            try? await Task.sleep(for: .seconds(2))
        }
        let js = """
        const r = await fetch('/api/organizations', {credentials:'include'});
        if (!r.ok) return '[]';
        return JSON.stringify(await r.json());
        """
        guard let s = try await v.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) as? String,
              let d = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { o in
            guard let id = o["uuid"] as? String else { return nil }
            return (id, (o["name"] as? String) ?? "Organization")
        }
    }

    func fetchUsage(for account: Account) async throws -> FetchedUsage {
        let v = view(for: account)
        if v.url == nil {
            v.load(URLRequest(url: URL(string: "https://claude.ai/")!))
            try? await Task.sleep(for: .seconds(3))
        }
        let js = """
        const orgs = await (await fetch('/api/organizations', {credentials:'include'})).json();
        if (!Array.isArray(orgs) || !orgs.length) return JSON.stringify({error:'no-orgs'});
        const id = orgs[0].uuid;
        const r = await fetch('/api/organizations/' + id + '/usage', {credentials:'include'});
        return JSON.stringify({status:r.status, body: await r.text()});
        """
        let raw = try await v.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page)
        guard let s = raw as? String, let d = s.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { throw AdapterError.transport("unreadable bridge result") }
        if outer["error"] as? String == "no-orgs" { throw AdapterError.notSignedIn }
        guard (outer["status"] as? Int) == 200,
              let body = (outer["body"] as? String)?.data(using: .utf8)
        else { throw AdapterError.notSignedIn }
        return try AnthropicParser.parse(body)
    }
}

enum AnthropicParser {
    /// Mirrors the five_hour / seven_day shape the Electron app normalises.
    static func parse(_ data: Data) throws -> FetchedUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON")
        }
        func pool(_ key: String, _ label: String) -> UsageLimit? {
            guard let d = root[key] as? [String: Any],
                  let pct = d["utilization"] as? Double else { return nil }
            var reset: Date?
            if let s = d["resets_at"] as? String {
                reset = ISO8601DateFormatter().date(from: s)
            }
            return .init(key: key, label: label, percent: pct, resetsAt: reset)
        }
        let limits = [pool("five_hour", "5-hour limit"),
                      pool("seven_day", "Weekly · all models")].compactMap { $0 }
        return FetchedUsage(plan: nil, limits: limits)
    }
}
