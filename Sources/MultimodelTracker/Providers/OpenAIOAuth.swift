import Foundation
import AppKit
import CryptoKit
import Network

/// Signs an OpenAI account in through the user's REAL browser.
///
/// The embedded WKWebView cannot do passkeys: WebAuthn there needs the
/// restricted `com.apple.developer.web-browser.public-key-credential`
/// entitlement, which Apple issues only against a provisioning profile and
/// which macOS refuses on ad-hoc builds. "Continue with passkey" therefore
/// does nothing at all in the mini window — and some ChatGPT accounts are
/// passkey-only, so that is a wall rather than an inconvenience.
///
/// The system browser has none of those limits, so this runs the same OAuth
/// PKCE flow Codex CLI uses: open auth.openai.com in the default browser,
/// catch the redirect on a loopback listener, exchange the code for tokens.
/// It also yields a refresh token, which the cookie-jar route never did.
enum OpenAIOAuth {
    /// Codex CLI's public client. Its redirect URI is registered as this
    /// exact loopback address, so the port is not ours to choose.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let port: UInt16 = 1455

    struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let accountID: String?
        let email: String?
    }

    enum Failure: LocalizedError {
        case portBusy
        case cancelled
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .portBusy:
                return "Port 1455 is busy — quit any Codex CLI login in progress and retry."
            case .cancelled:
                return "Sign-in was cancelled or timed out."
            case .badResponse(let s):
                return "OpenAI rejected the sign-in: \(s)"
            }
        }
    }

    static func signIn() async throws -> Tokens {
        let verifier = randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomURLSafe(24)

        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // OpenAI-specific: without these the issued token lacks the
            // organisation/account claims the usage endpoint needs.
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
        ]

        // Listen BEFORE opening the browser, or a fast redirect races us.
        let waiter = try LoopbackCatcher(port: port, expectedState: state)
        defer { waiter.stop() }
        NSWorkspace.shared.open(comps.url!)

        let code = try await waiter.awaitCode()
        return try await exchange(code: code, verifier: verifier)
    }

    private static func exchange(code: String, verifier: String) async throws -> Tokens {
        let fields = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
        ]
        return try await post(fields)
    }

    /// Refreshes without any browser round trip — the reason this flow beats
    /// the cookie jar for long-lived accounts.
    static func refresh(_ refreshToken: String) async throws -> Tokens {
        let fields = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "scope": "openid profile email offline_access",
        ]
        let t = try await post(fields)
        // A refresh may or may not rotate the token; keep the old one when it
        // doesn't, or the account silently becomes unrefreshable.
        return Tokens(accessToken: t.accessToken,
                      refreshToken: t.refreshToken ?? refreshToken,
                      accountID: t.accountID, email: t.email)
    }

    private static func post(_ fields: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            throw Failure.badResponse(String(snippet))
        }
        var accountID: String?
        var email: String?
        if let idToken = obj["id_token"] as? String {
            let claims = decodeJWT(idToken)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            accountID = (auth?["chatgpt_account_id"] as? String) ?? (claims["sub"] as? String)
            email = claims["email"] as? String
        }
        return Tokens(accessToken: access,
                      refreshToken: obj["refresh_token"] as? String,
                      accountID: accountID, email: email)
    }

    private static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return Data(raw).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot loopback HTTP listener for the OAuth redirect. Deliberately
/// minimal: read the request line, answer once, stop.
private final class LoopbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let expectedState: String
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private let lock = NSLock()

    init(port: UInt16, expectedState: String) throws {
        self.expectedState = expectedState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw OpenAIOAuth.Failure.portBusy }
        do { listener = try NWListener(using: params, on: nwPort) }
        catch { throw OpenAIOAuth.Failure.portBusy }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func awaitCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            // The browser may never come back (tab closed); don't hang forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(OpenAIOAuth.Failure.cancelled))
            }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value
            let state = items.first { $0.name == "state" }?.value
            let err = items.first { $0.name == "error" }?.value

            let ok = err == nil && code != nil && state == self.expectedState
            let message = ok
                ? "Signed in. You can close this tab and return to Multimodel Tracker."
                : "Sign-in failed: \(err ?? "unexpected response"). Return to Multimodel Tracker and try again."
            let html = "<!doctype html><meta charset=utf-8><title>Multimodel Tracker</title>"
                + "<body style=\"font:15px -apple-system,system-ui;margin:60px auto;max-width:32em\">"
                + "<p>\(message)</p></body>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

            if ok, let code {
                self.finish(.success(code))
            } else if err != nil || code != nil {
                // Only fail on a real callback; ignore favicon and stray hits.
                self.finish(.failure(OpenAIOAuth.Failure.badResponse(err ?? "state mismatch")))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        cont.resume(with: result)
        listener.cancel()
    }
}
