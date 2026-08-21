import AppKit
import WebKit

/// Provider sign-in. Each account logs in inside its OWN WKWebView data
/// store, so four claude.ai subscriptions stay signed in simultaneously —
/// the thing a single shared cookie jar makes impossible.
///
/// There is no OAuth here to intercept: claude.ai is cookie/session based, so
/// "signed in" is detected by asking the API whether it answers, rather than
/// by watching for a redirect URL.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    /// Live controllers, keyed by account. The poll only runs while the
    /// controller is alive, so ownership can't be left to SwiftUI view
    /// state — closing the Accounts window would silently kill detection
    /// and strand the sign-in window open as a Claude chat.
    private static var active: [UUID: SignInWindowController] = [:]
    private var window: NSWindow?
    private var poll: Timer?
    private let account: Account
    private let onFinished: (Bool) -> Void

    var email: String? { signedInEmail }

    init(account: Account, onFinished: @escaping (Bool) -> Void) {
        self.account = account
        self.onFinished = onFinished
        super.init()
    }

    func present() {
        Self.active[account.id] = self
        let web = WebSessionPool.shared.signInView(for: account)
        web.removeFromSuperview()          // leave the hidden host
        web.frame = NSRect(x: 0, y: 0, width: 520, height: 720)

        // Passkeys cannot work here and fail SILENTLY: WebAuthn inside a
        // WKWebView needs com.apple.developer.web-browser-public-key-credential,
        // which Apple grants only to apps that register as default browsers.
        // Without it navigator.credentials is absent, so "Continue with
        // passkey" does nothing at all and the user is stuck with no error.
        // Say so up front rather than let them click into a dead end.
        let banner = NSTextField(labelWithString:
            "Passkeys don\u{2019}t work in this window — use email & password"
            + (account.provider == .openai ? ", or Import Codex CLI." : "."))
        banner.font = .systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.alignment = .center
        banner.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: web.frame)
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(banner)
        container.addSubview(web)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            web.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 7),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let w = NSWindow(contentRect: web.frame,
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in — \(account.displayName)"
        w.contentView = container
        w.delegate = self
        // Above the Accounts panel (also .floating — later ordering wins) and
        // pinned on top: this window has no Dock/task-manager presence, so if
        // it slips behind something the user has to hunt for it or start the
        // sign-in over.
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.placeNearMenuBar()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        // Poll rather than watch navigation: the session can become valid
        // without a distinguishing redirect (existing cookie, SSO bounce,
        // 2FA interstitial), and the only authority on "am I logged in" is
        // whether the API answers.
        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSignedIn() }
        }
    }

    private func checkSignedIn() async {
        switch account.provider {
        case .anthropic:
            guard let orgs = try? await WebSessionPool.shared.organizations(for: account),
                  !orgs.isEmpty else { return }
            finish(success: true)
        case .openai:
            guard let session = try? await WebSessionPool.shared.openAIWebSession(for: account) ?? nil
            else { return }
            // Store BEFORE announcing success — the refresh the completion
            // fires reads these credentials.
            Keychain.storeOpenAI(accessToken: session.accessToken,
                                 accountId: session.accountId, for: account.id)
            signedInEmail = session.email
            finish(success: true)
        case .google:
            finish(success: false)
        }
    }

    /// Email seen during OpenAI sign-in, surfaced so the account row can
    /// show whose login this is.
    private(set) var signedInEmail: String?

    private func finish(success: Bool) {
        Self.active[account.id] = nil
        poll?.invalidate(); poll = nil
        window?.delegate = nil
        window?.close(); window = nil
        onFinished(success)
    }

    func windowWillClose(_ notification: Notification) {
        Self.active[account.id] = nil
        poll?.invalidate(); poll = nil
        onFinished(false)
    }
}
