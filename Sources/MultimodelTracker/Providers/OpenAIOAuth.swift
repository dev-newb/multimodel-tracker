import Foundation
import AppKit

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
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .portBusy:
                return "Port 1455 is busy — quit any Codex CLI login in progress and retry."
            case .badResponse(let s):
                return "OpenAI rejected the sign-in: \(s)"
            }
        }
    }

    static func signIn() async throws -> Tokens {
        let verifier = OAuthPKCE.randomURLSafe(64)
        let state = OAuthPKCE.randomURLSafe(24)

        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // OpenAI-specific: without these the issued token lacks the
            // organisation/account claims the usage endpoint needs.
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
        ]

        do {
            // Listen BEFORE opening the browser, or a fast redirect races us.
            let waiter = try LoopbackCatcher(port: port, expectedState: state)
            defer { waiter.stop() }
            _ = try await waiter.ready()
            NSWorkspace.shared.open(comps.url!)
            let code = try await waiter.awaitCode()
            return try await exchange(code: code, verifier: verifier)
        } catch LoopbackError.portBusy {
            // The generic message can't know WHO holds 1455; here we do.
            throw Failure.portBusy
        }
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
            let claims = JWT.claims(idToken)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            accountID = (auth?["chatgpt_account_id"] as? String) ?? (claims["sub"] as? String)
            email = claims["email"] as? String
        }
        return Tokens(accessToken: access,
                      refreshToken: obj["refresh_token"] as? String,
                      accountID: accountID, email: email)
    }
}

enum JWT {
    static func claims(_ token: String) -> [String: Any] {
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
}
