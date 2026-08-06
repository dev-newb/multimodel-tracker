import Foundation

/// Google has no public OAuth client for this, so the id/secret are borrowed
/// from a locally installed gemini-cli — they are public constants shipped
/// inside its npm bundle. Scanning the install matches whatever client the
/// user's CLI actually uses instead of pinning a copy that can rot.
///
/// NOTE: gemini-cli is on a deprecation path and Antigravity ships no
/// extractable client, so this borrowing has a shelf life. When it breaks,
/// the replacement is registering a Cloud OAuth client of our own.
enum GeminiOAuthClient {
    struct Client { let id: String; let secret: String }
    private static var cached: Client??

    /// Antigravity's OAuth client, read out of its shipped binaries. The
    /// gemini-cli client that used to be scanned for here does NOT work:
    /// a refresh token is bound to the client that issued it, and pairing
    /// gemini-cli's client with Antigravity's token returns 401 every time
    /// (verified against the live token endpoint). Google has also started
    /// answering the CLI client with UNSUPPORTED_CLIENT and telling users to
    /// migrate to Antigravity, so this is the one with a future.
    static func discover() -> Client? {
        if let c = cached { return c }
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy"),
        ]
        // Client id and secret are not adjacent in the binary, so they are
        // matched separately rather than by one proximity regex.
        let idPattern = try! NSRegularExpression(
            pattern: "[0-9]{10,}-[a-z0-9]{20,}\\.apps\\.googleusercontent\\.com")
        let secretPattern = try! NSRegularExpression(pattern: "GOCSPX-[A-Za-z0-9_-]{20,}")

        for url in candidates {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            // ASCII scan: these are Mach-O binaries, so decode lossily.
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            guard let idM = idPattern.firstMatch(in: text, range: range),
                  let idR = Range(idM.range, in: text),
                  let scM = secretPattern.firstMatch(in: text, range: range),
                  let scR = Range(scM.range, in: text) else { continue }
            // Secrets sit back to back in the binary with no separator; the
            // regex bounds each one, but trim to the known 35-char length.
            let secret = String(String(text[scR]).prefix(35))
            let c = Client(id: String(text[idR]), secret: secret)
            cached = c
            return c
        }
        cached = Client?.none
        return nil
    }
}

/// Two places a Google login can already exist on this Mac. Both carry a
/// live access token alongside the refresh token, so a read usually needs no
/// OAuth round trip at all.
enum GoogleCredentialSource {
    struct TokenBlob {
        let accessToken: String?
        let refreshToken: String?
        let expiry: Date?
    }

    private static func parse(_ root: [String: Any]) -> TokenBlob {
        let tok = (root["token"] as? [String: Any]) ?? root
        func pick(_ o: [String: Any], _ keys: [String]) -> String? {
            for k in keys { if let v = o[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let expiryString = pick(tok, ["expiry", "expiry_date", "expires_at"])
        return TokenBlob(
            accessToken: pick(tok, ["access_token", "accessToken"]),
            refreshToken: pick(tok, ["refresh_token", "refreshToken", "RefreshToken"]),
            expiry: expiryString.flatMap { iso.date(from: $0) ?? plain.date(from: $0) })
    }

    /// gemini-cli writes a plain JSON file.
    static func geminiCLITokenBlob() -> TokenBlob? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard let d = try? Data(contentsOf: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return parse(o)
    }

    /// Per-launch cache of the raw keychain payload. THIS ITEM BELONGS TO
    /// ANOTHER APP (Antigravity), so its ACL does not list us and macOS
    /// prompts on every read until the user grants Always Allow. Reading it
    /// once per poll therefore meant a password prompt every three minutes.
    /// One read per launch, cached — including the failure, so a denied
    /// prompt doesn't immediately ask again.
    private static var keychainCache: String??
    private static let keychainQueue = DispatchQueue(label: "com.devnewb.multimodeltracker.google")

    /// Off the main actor: SecItemCopyMatching blocks for as long as the
    /// password panel is up, and Store is @MainActor — reading it inline
    /// froze the whole UI behind the prompt.
    static func antigravityKeychainBlobAsync() async -> String? {
        if let cached = keychainCache { return cached }
        let value: String? = await withCheckedContinuation { cont in
            keychainQueue.async {
                if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
                    FileHandle.standardError.write("google keychain READ (cache miss)\n".data(using: .utf8)!)
                }
                cont.resume(returning: antigravityKeychainBlob())
            }
        }
        keychainCache = value
        return value
    }

    /// Antigravity keeps its login in the login keychain rather than a file —
    /// the SAME item serves both the IDE and the `agy` CLI, so one read covers
    /// both. macOS gates this with a consent prompt; Always Allow makes it
    /// silent from then on.
    static func antigravityKeychainBlob() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "gemini",
                                kSecAttrAccount as String: "antigravity",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Antigravity stores through Go's go-keyring, which wraps the payload as
    /// `go-keyring-base64:<base64>`. Inside is plain JSON:
    ///   { "auth_method": …, "id_token": …, "token": { access_token,
    ///     token_type, refresh_token, expiry } }
    static func antigravityTokenBlob() async -> TokenBlob? {
        guard let raw = await antigravityKeychainBlobAsync() else { return nil }
        let body = raw.range(of: "go-keyring-base64:").map { String(raw[$0.upperBound...]) } ?? raw
        guard let decoded = Data(base64Encoded: body),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return raw.hasPrefix("1//") ? TokenBlob(accessToken: nil, refreshToken: raw, expiry: nil) : nil }
        return parse(root)
    }
}

struct GoogleAdapterImpl: UsageAdapter {
    func fetch(account: Account) async throws -> FetchedUsage {
        guard let blob = await GoogleCredentialSource.antigravityTokenBlob()
                ?? GoogleCredentialSource.geminiCLITokenBlob() else {
            throw AdapterError.notSignedIn
        }
        // The stored access token is usually still live; only pay for a
        // refresh when it isn't. That also means a working read even if the
        // OAuth client can't be located.
        if let token = blob.accessToken, blob.expiry.map({ $0 > Date().addingTimeInterval(60) }) ?? false,
           let usage = try? await loadQuota(token: token) {
            return usage
        }
        guard let refresh = blob.refreshToken else { throw AdapterError.notSignedIn }
        guard let client = GeminiOAuthClient.discover() else {
            throw AdapterError.notImplemented("Antigravity install not found (its OAuth client is required)")
        }
        let access = try await exchange(refresh: refresh, client: client)
        return try await loadQuota(token: access)
    }

    private func exchange(refresh: String, client: GeminiOAuthClient.Client) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "client_id=\(client.id)&client_secret=\(client.secret)"
            + "&refresh_token=\(refresh)&grant_type=refresh_token"
        req.httpBody = form.data(using: .utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["access_token"] as? String else { throw AdapterError.notSignedIn }
        return t
    }

    /// `v1internal:retrieveUserQuota` with an EMPTY body. Verified live
    /// against Rich's Antigravity login; it answers with per-model buckets:
    ///   { buckets: [ { modelId, tokenType, remainingFraction, resetTime } ] }
    /// The endpoint this used to call — loadCodeAssist — carries no usage at
    /// all, only tier eligibility, which is why the parse never round-tripped.
    /// retrieveUserQuotaSummary exists but answers 403 for this account.
    private func loadQuota(token: String) async throws -> FetchedUsage {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw AdapterError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AdapterError.notSignedIn }
        guard http.statusCode == 200 else { throw AdapterError.transport("HTTP \(http.statusCode)") }
        guard let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]] else {
            throw AdapterError.transport("no quota buckets in response")
        }
        let iso = ISO8601DateFormatter()
        let limits: [UsageLimit] = buckets.compactMap { b in
            guard let model = b["modelId"] as? String else { return nil }
            // remainingFraction is REMAINING; the bars show used.
            let used = (b["remainingFraction"] as? Double).map { (1 - $0) * 100 }
            let type = (b["tokenType"] as? String) ?? ""
            let label = type == "REQUESTS" ? model : "\(model) · \(type.lowercased())"
            return UsageLimit(key: "\(model)_\(type)", label: label, percent: used,
                              resetsAt: (b["resetTime"] as? String).flatMap { iso.date(from: $0) })
        }
        guard !limits.isEmpty else { throw AdapterError.transport("quota response had no models") }
        return FetchedUsage(plan: nil, limits: limits)
    }
}
