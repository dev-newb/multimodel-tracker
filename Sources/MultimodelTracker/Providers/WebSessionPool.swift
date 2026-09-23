import WebKit

/// One hidden WKWebView per LEGACY account, each with its OWN data store.
/// New sign-ins go through the browser OAuth flows and never touch this pool;
/// it survives for the accounts that predate them — claude.ai cookie jars and
/// chatgpt.com sessions that can still re-mint a token — so an upgrade never
/// logs anyone out.
///
/// A browser engine is required rather than URLSession: claude.ai is behind
/// Cloudflare, which rejects plain HTTP client fingerprints. WebKit passes —
/// verified: an empty jar reaches the real API and gets Anthropic's own
/// account_session_invalid JSON rather than a challenge page.
@MainActor
final class WebSessionPool {
    static let shared = WebSessionPool()
    private var views: [UUID: WKWebView] = [:]

    /// WebKit suspends zero-sized, windowless views — scripts then complete
    /// with nil. Parking every pooled view inside one hidden window keeps
    /// them live, the same trick the Electron tracker uses with its hidden
    /// BrowserWindow. The window is never shown.
    private lazy var host: NSWindow = {
        // Parked far OFF-SCREEN. At (0,0) this invisible window occupied a
        // real 900x700 patch of the display, and the WKWebViews inside it are
        // the only thing in this app that sets I-beam and resize cursors —
        // text and page furniture under a pointer WebKit still tracks. Rich
        // saw exactly those, and only over the rows sitting in that region.
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.orderOut(nil)
        return w
    }()

    private var bridges: [UUID: BridgeChannel] = [:]

    private func view(for account: Account) -> WKWebView {
        if let v = views[account.id] { return v }
        let cfg = WKWebViewConfiguration()
        let channel = BridgeChannel()
        cfg.userContentController.add(channel, name: "mmt")
        bridges[account.id] = channel
        if #available(macOS 14.0, *) {
            // Persistent AND isolated: survives relaunch, never shares cookies.
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
        } else {
            cfg.websiteDataStore = .nonPersistent()
        }
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: cfg)
        host.contentView?.addSubview(v)
        // Deliberately NOT spoofing a Chrome UA here. Claiming to be Chrome
        // from a WebKit engine is an inconsistency bot-detection flags, and it
        // put sign-in into an unsolvable challenge loop. Present honestly as
        // the Safari-family browser we actually are and the challenge resolves
        // like it would in Safari.
        views[account.id] = v
        return v
    }

    /// Runs JS and receives the result as a POSTED MESSAGE rather than a
    /// return value. callAsyncJavaScript's marshalling proved unreliable here
    /// — with the page fully loaded even `return 'pong'` came back Void — so
    /// the bridge uses WKScriptMessageHandler, the channel that doesn't
    /// depend on it. The JS is fire-and-forget; the payload arrives via
    /// webkit.messageHandlers.mmt.postMessage.
    private func callBridge(_ body: String, in v: WKWebView, for account: UUID) async throws -> String {
        guard let channel = bridges[account] else {
            throw AdapterError.transport("no bridge channel")
        }
        for attempt in 0..<6 {
            if v.isLoading { try? await Task.sleep(for: .seconds(1)); continue }
            let id = UUID().uuidString
            let wrapped = """
            (async () => {
              try {
                const out = await (async () => { \(body) })();
                webkit.messageHandlers.mmt.postMessage(JSON.stringify({id: '\(id)', ok: true, out}));
              } catch (e) {
                webkit.messageHandlers.mmt.postMessage(JSON.stringify({id: '\(id)', ok: false, err: String(e)}));
              }
            })();
            """
            async let reply = channel.wait(for: id, seconds: 8)
            v.evaluateJavaScript(wrapped, completionHandler: nil)
            if let r = await reply {
                if r.ok { return r.out ?? "" }
                throw AdapterError.transport("page JS: \(r.err ?? "unknown")")
            }
            try? await Task.sleep(for: .seconds(1 + Double(attempt) * 0.5))
        }
        throw AdapterError.transport("page never produced a bridge result")
    }

    struct OpenAIWebSession {
        let accessToken: String
        let accountId: String?
        let email: String?
    }

    /// Mints an access token from the chatgpt.com cookie session — the same
    /// bridge trick as Anthropic, but the token comes back out and lives in
    /// the keychain because OpenAI's usage endpoint is a plain bearer GET.
    /// Nil when the jar has no valid session (that's also how sign-in
    /// completion is detected). Because the cookies persist in the account's
    /// data store, this can silently re-mint after the token expires.
    func openAIWebSession(for account: Account) async throws -> OpenAIWebSession? {
        let v = view(for: account)
        if v.url == nil {
            v.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
            try? await Task.sleep(for: .seconds(2))
        }
        let js = """
        const r = await fetch('https://chatgpt.com/api/auth/session', {credentials:'include'});
        return JSON.stringify({status: r.status, body: await r.text()});
        """
        let s = try await callBridge(js, in: v, for: account.id)
        guard let d = s.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (outer["status"] as? Int) == 200,
              let bodyData = (outer["body"] as? String)?.data(using: .utf8),
              let session = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let token = session["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let email = (session["user"] as? [String: Any])?["email"] as? String
        return OpenAIWebSession(accessToken: token,
                                accountId: Self.chatGPTAccountId(fromJWT: token),
                                email: email)
    }

    /// The workspace id rides inside the token's auth claim; personal
    /// accounts may not carry one, and the usage endpoint accepts that.
    private static func chatGPTAccountId(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    /// One line per probe: does a trivial return work, does fetch work.
    func bridgeDiagnostics(for account: Account) async -> String {
        let v = view(for: account)
        if v.url == nil { v.load(URLRequest(url: URL(string: "https://claude.ai/")!)) }
        var lines: [String] = []
        for wait in [3, 5] { try? await Task.sleep(for: .seconds(wait))
            lines.append("loading=\(v.isLoading) url=\(v.url?.host ?? "nil")")
            for (name, js) in [("ping", "return 'pong'"),
                               ("fetch", "const r = await fetch('https://claude.ai/api/organizations', {credentials:'include'}); return String(r.status);")] {
                do {
                    let r = try await callBridge(js, in: v, for: account.id)
                    lines.append("\(name)=\(r)")
                } catch { lines.append("\(name)=throw:\(error)") }
            }
        }
        return lines.joined(separator: " | ")
    }

    func fetchUsage(for account: Account) async throws -> FetchedUsage {
        let v = view(for: account)
        if v.url == nil {
            v.load(URLRequest(url: URL(string: "https://claude.ai/")!))
            try? await Task.sleep(for: .seconds(3))
        }
        let js = """
        const orgs = await (await fetch('https://claude.ai/api/organizations', {credentials:'include'})).json();
        if (!Array.isArray(orgs) || !orgs.length) return JSON.stringify({error:'no-orgs'});
        const id = orgs[0].uuid;
        const r = await fetch('https://claude.ai/api/organizations/' + id + '/usage', {credentials:'include'});
        return JSON.stringify({status:r.status, body: await r.text()});
        """
        let s = try await callBridge(js, in: v, for: account.id)
        guard let d = s.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AdapterError.transport("bad bridge payload: \(s.prefix(80))")
        }
        if let e = outer["error"] as? String {
            throw e == "no-orgs" ? AdapterError.notSignedIn : AdapterError.transport(e)
        }
        let status = outer["status"] as? Int ?? 0
        guard status == 200, let body = (outer["body"] as? String)?.data(using: .utf8) else {
            throw status == 401 || status == 403
                ? AdapterError.notSignedIn
                : AdapterError.transport("usage HTTP \(status)")
        }
        return try AnthropicParser.parse(body)
    }
}

enum AnthropicParser {
    /// The usage payload's `limits` array is the structured source: one entry
    /// per pool with kind (session / weekly_all / weekly_scoped), percent,
    /// resets_at and — for scoped pools — the model's display name. Parsing
    /// it means Fable-style pools appear by name without hardcoding models.
    static func parse(_ data: Data) throws -> FetchedUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON")
        }
        // resets_at carries fractional seconds ("…T10:40:00.776260+00:00"),
        // which a default ISO8601DateFormatter rejects outright.
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }

        var limits: [UsageLimit] = []
        for (i, e) in ((root["limits"] as? [[String: Any]]) ?? []).enumerated() {
            guard let pct = e["percent"] as? Double else { continue }
            let kind = e["kind"] as? String ?? "limit"
            let label: String
            switch kind {
            case "session":    label = "5-hour limit"
            case "weekly_all": label = "Weekly · all models"
            case "weekly_scoped":
                let model = ((e["scope"] as? [String: Any])?["model"] as? [String: Any])
                label = "Weekly · \((model?["display_name"] as? String) ?? "scoped")"
            default:           label = kind
            }
            limits.append(.init(key: "\(kind)_\(i)", label: label,
                                percent: pct, resetsAt: date(e["resets_at"])))
        }

        // Older payload shape as a fallback, so the card never goes blank if
        // the array disappears.
        if limits.isEmpty {
            for (key, label) in [("five_hour", "5-hour limit"), ("seven_day", "Weekly · all models")] {
                if let d = root[key] as? [String: Any], let pct = d["utilization"] as? Double {
                    limits.append(.init(key: key, label: label, percent: pct, resetsAt: date(d["resets_at"])))
                }
            }
        }
        return FetchedUsage(plan: nil, limits: limits)
    }
}

/// Receives bridge replies. One instance per webview; continuations are
/// keyed by call id so concurrent calls can't steal each other's answers.
final class BridgeChannel: NSObject, WKScriptMessageHandler {
    struct Reply { let ok: Bool; let out: String?; let err: String? }
    private var waiters: [String: CheckedContinuation<Reply?, Never>] = [:]
    private let lock = NSLock()

    func wait(for id: String, seconds: Double) async -> Reply? {
        await withCheckedContinuation { (c: CheckedContinuation<Reply?, Never>) in
            lock.lock(); waiters[id] = c; lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiter = self.waiters.removeValue(forKey: id)
                self.lock.unlock()
                waiter?.resume(returning: nil)          // timed out
            }
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String else { return }
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(returning: Reply(ok: o["ok"] as? Bool ?? false,
                                        out: o["out"] as? String,
                                        err: o["err"] as? String))
    }
}
