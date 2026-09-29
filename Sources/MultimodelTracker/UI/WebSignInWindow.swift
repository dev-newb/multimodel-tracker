import AppKit
import WebKit

/// Runs Anthropic's authorize page INSIDE the tracker, in the same
/// per-account cookie jar WebSessionPool reads, instead of the system
/// browser. One login then leaves two things behind: the OAuth token (the
/// redirect is caught here and handed to the loopback waiter, exactly as a
/// browser hit on the socket would be) and the claude.ai session cookie --
/// the only surface on which Anthropic answers with banked-reset grants
/// (OAuth answers ineligible_reason "surface").
///
/// The system browser stays one click away: "Use my browser instead" hands
/// the SAME authorize URL to it, and the loopback listener -- still bound --
/// catches that redirect too. That path gives a token but no web session,
/// which is the honest trade for Google sign-in and passkeys, neither of
/// which works in an embedded WKWebView.
@MainActor
final class WebSignInWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private let account: UUID
    private var window: NSWindow?
    private var web: WKWebView?
    private var status: NSTextField?
    private var authorizeURL: URL?
    private var redirect = ""
    private var deliver: ((URL) -> Void)?
    private var cancel: (() -> Void)?
    private var closingOnPurpose = false
    /// The user took the system-browser route: a token will come, a web session won't.
    private(set) var fellBack = false

    init(account: UUID) { self.account = account }

    func present(_ url: URL, _ redirect: String,
                 _ deliver: @escaping @Sendable (URL) -> Void,
                 _ cancel: @escaping @Sendable () -> Void) -> Bool {
        authorizeURL = url; self.redirect = redirect
        self.deliver = deliver; self.cancel = cancel

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WebSessionPool.shared.dataStore(for: account)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(wrappingLabelWithString:
            "Signing in here also lets the tracker see banked resets. Google sign-in or a passkey won't work in this window — use your browser for those.")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let fallback = NSButton(title: "Use my browser instead", target: self, action: #selector(useBrowser))
        fallback.bezelStyle = .rounded
        fallback.controlSize = .small
        fallback.setContentHuggingPriority(.required, for: .horizontal)
        let bar = NSStackView(views: [status, fallback])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(web); root.addSubview(bar)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in to Claude"
        w.isReleasedWhenClosed = false
        w.contentView = root
        w.delegate = self
        w.center()
        self.window = w; self.web = web; self.status = status
        web.load(URLRequest(url: url))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// After the token: make sure this jar holds a claude.ai session. The
    /// authorize page lives on claude.com, so its login may or may not
    /// leave a claude.ai cookie; if not, claude.ai is opened in the same
    /// window, where an existing claude.com login usually carries straight
    /// over. Returns whether a session is there. Always closes the window.
    func captureSession() async -> Bool {
        defer { close() }
        guard !fellBack, let web, window != nil else { return false }
        let jar = web.configuration.websiteDataStore.httpCookieStore
        if await hasClaudeSession(jar) { log("claude.ai session present after authorize"); return true }
        status?.stringValue = "One more step: opening claude.ai so the tracker can see banked resets…"
        web.load(URLRequest(url: URL(string: "https://claude.ai/")!))
        let started = Date()
        while window != nil, Date().timeIntervalSince(started) < 300 {
            try? await Task.sleep(for: .milliseconds(500))
            if await hasClaudeSession(jar) {
                log(String(format: "claude.ai session appeared %.1fs after opening claude.ai", Date().timeIntervalSince(started)))
                return true
            }
        }
        log("no claude.ai session (window closed or timed out)")
        return false
    }

    func close() {
        guard let window else { return }
        closingOnPurpose = true
        window.close()
        self.window = nil; web = nil
    }

    @objc private func useBrowser() {
        guard let authorizeURL else { return }
        fellBack = true
        log("fell back to the system browser")
        close()
        NSWorkspace.shared.open(authorizeURL)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingOnPurpose else { return }
        window = nil; web = nil
        if !fellBack { cancel?() }        // before the token: nothing changes
    }

    /// The redirect to the loopback is caught here rather than loaded: the
    /// code goes straight to the waiter, and the window shows a local page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.absoluteString.hasPrefix(redirect) {
            decisionHandler(.cancel)
            log("caught the authorize redirect in-app")
            deliver?(url)
            webView.loadHTMLString("""
                <meta charset=utf-8><body style="font:14px -apple-system;color:#888;text-align:center;margin-top:120px">
                Signed in. Finishing up…</body>
                """, baseURL: nil)
            return
        }
        decisionHandler(.allow)
    }

    private func hasClaudeSession(_ jar: WKHTTPCookieStore) async -> Bool {
        await jar.allCookies().contains { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") }
    }

    private func log(_ s: String) {
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write("web-signin \(account.uuidString.prefix(8)): \(s)\n".data(using: .utf8)!)
        }
    }
}
