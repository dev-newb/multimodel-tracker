import Foundation
import AppKit

/// Signs an additional Google account in through the real browser, using
/// Antigravity's own OAuth client — the same installed-app flow gemini-cli
/// runs. This is what makes MORE THAN ONE Google account possible: the
/// Antigravity keychain item and the gemini-cli file each hold exactly one
/// login, so importing could only ever produce a single row. A browser
/// sign-in mints a refresh token we store ourselves, per account.
///
/// The client id and secret are discovered from Antigravity's binaries (see
/// GeminiOAuthClient) because a refresh token is bound to the client that
/// issued it: a token minted here must be redeemable by the same pair the
/// adapter later refreshes with.
enum GoogleOAuth {
    /// What cloudcode-pa needs, plus the identity scopes so the row can name
    /// its account.
    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ].joined(separator: " ")

    struct Tokens { let refreshToken: String; let accessToken: String?; let email: String? }

    enum Failure: LocalizedError {
        case noClient, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noClient:
                return "Antigravity isn't installed, so there's no Google client to sign in with."
            case .badResponse(let s): return "Google rejected the sign-in: \(s)"
            }
        }
    }

    static func signIn() async throws -> Tokens {
        guard let client = GeminiOAuthClient.candidates().first else { throw Failure.noClient }
        let verifier = OAuthPKCE.randomURLSafe(64)
        let state = OAuthPKCE.randomURLSafe(24)

        // Listen before opening the browser, and use the port the system
        // actually granted — Google allows any loopback port for an
        // installed-app client.
        let waiter = try LoopbackCatcher(port: 0, expectedState: state)
        defer { waiter.stop() }
        let port = try await waiter.ready()
        let redirect = "http://localhost:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Without both of these Google returns no refresh token for an
            // account that has already consented once.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        guard NSWorkspace.shared.open(comps.url!) else {
            throw Failure.badResponse("the browser could not be opened")
        }
        let code = try await waiter.awaitCode()

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: client.id),
            .init(name: "client_secret", value: client.secret),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = obj["refresh_token"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw Failure.badResponse(String(snippet))
        }
        let email = (obj["id_token"] as? String).flatMap(GoogleAdapterImpl.emailFromJWT)
        return Tokens(refreshToken: refresh, accessToken: obj["access_token"] as? String, email: email)
    }
}
