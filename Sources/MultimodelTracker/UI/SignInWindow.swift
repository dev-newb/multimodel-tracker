import AppKit
import WebKit

/// Anthropic sign-in. Each account logs in inside its OWN WKWebView data
/// store, so four claude.ai subscriptions stay signed in simultaneously —
/// the thing a single shared cookie jar makes impossible.
///
/// There is no OAuth here to intercept: claude.ai is cookie/session based, so
/// "signed in" is detected by asking the API whether it answers, rather than
/// by watching for a redirect URL.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var poll: Timer?
    private let account: Account
    private let onFinished: (Bool) -> Void

    init(account: Account, onFinished: @escaping (Bool) -> Void) {
        self.account = account
        self.onFinished = onFinished
        super.init()
    }

    func present() {
        let web = WebSessionPool.shared.signInView(for: account)
        web.frame = NSRect(x: 0, y: 0, width: 520, height: 720)

        let w = NSWindow(contentRect: web.frame,
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in — \(account.displayName)"
        w.contentView = web
        w.delegate = self
        w.center()
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
        guard let orgs = try? await WebSessionPool.shared.organizations(for: account),
              !orgs.isEmpty else { return }
        finish(success: true)
    }

    private func finish(success: Bool) {
        poll?.invalidate(); poll = nil
        window?.delegate = nil
        window?.close(); window = nil
        onFinished(success)
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate(); poll = nil
        onFinished(false)
    }
}
