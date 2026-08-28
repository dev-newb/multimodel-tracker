import Foundation
import AppKit

/// Signs a Claude account in through the user's REAL browser — the same
/// PKCE flow the OpenAI accounts use, replacing the embedded claude.ai
/// window. The browser brings what the WKWebView never could: passkeys work,
/// and an already-signed-in claude.ai session turns the whole flow into one
/// Authorize click. The result is an api.anthropic.com bearer token with a
/// refresh token, so polling needs no browser engine and no cookie jar.
///
/// Client id, endpoints, parameter names and body shapes are lifted from the
/// shipping Claude Code binary (2.1.246) — this IS "log in with your Claude
/// account", the flow every Claude Code install runs. Like that CLI, the
/// loopback redirect binds an EPHEMERAL port: Anthropic registers the
/// redirect for any localhost port, so there is no fixed number to contend
/// for (and no clash with a real Claude Code login in progress).
enum AnthropicOAuth {
    /// Claude Code's public client.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// The claude.ai (subscription) variant of the authorize page, not the
    /// platform/console one — Max plans live on the former.
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// The classic Claude Code scope trio. Tokens carrying it are accepted by
    /// api.anthropic.com/api/oauth/usage, which answers with the same
    /// limits[] payload as claude.ai's own usage endpoint.
    static let scopes = "org:create_api_key user:profile user:inference"
    /// Required on every api.anthropic.com request made with these tokens.
    static let betaHeader = "oauth-2025-04-20"

    struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let email: String?
    }

    enum Failure: LocalizedError {
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .badResponse(let s): return "Anthropic rejected the sign-in: \(s)"
            }
        }
    }

    static func signIn() async throws -> Tokens {
        let verifier = OAuthPKCE.randomURLSafe(64)
        let state = OAuthPKCE.randomURLSafe(24)

        // Listen BEFORE opening the browser, or a fast redirect races us —
        // and the redirect URI needs the port the system actually granted.
        let waiter = try LoopbackCatcher(port: 0, expectedState: state)
        defer { waiter.stop() }
        let port = try await waiter.ready()
        let redirect = "http://localhost:\(port)/callback"

        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let code = try await waiter.awaitCode()
        return try await post([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ])
    }

    /// Refreshes without any browser round trip.
    static func refresh(_ refreshToken: String) async throws -> Tokens {
        let t = try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        // A refresh may or may not rotate the token; keep the old one when it
        // doesn't, or the account silently becomes unrefreshable.
        return Tokens(accessToken: t.accessToken,
                      refreshToken: t.refreshToken ?? refreshToken,
                      expiresAt: t.expiresAt, email: t.email)
    }

    /// Anthropic's token endpoint takes JSON, not form encoding — the one
    /// mechanical difference from the OpenAI exchange.
    private static func post(_ fields: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: fields)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            throw Failure.badResponse(String(snippet))
        }
        let expiresAt = (obj["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        let email = (obj["account"] as? [String: Any])?["email_address"] as? String
        return Tokens(accessToken: access,
                      refreshToken: obj["refresh_token"] as? String,
                      expiresAt: expiresAt, email: email)
    }
}
