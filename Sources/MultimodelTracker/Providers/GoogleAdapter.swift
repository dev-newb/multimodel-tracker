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

    static func discover() -> Client? {
        if let c = cached { return c }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        /// Every layout a global npm install can take. A fixed list misses
        /// Homebrew on Apple Silicon and standalone node tarballs — the exact
        /// bug that made the Electron app claim "gemini-cli not found" on a
        /// machine that had it.
        func versioned(_ base: URL, _ tail: [String]) -> [URL] {
            (try? fm.contentsOfDirectory(atPath: base.path))?.compactMap { entry in
                tail.reduce(base.appendingPathComponent(entry)) { $0.appendingPathComponent($1) }
            } ?? []
        }
        var roots: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules"),
            URL(fileURLWithPath: "/usr/lib/node_modules"),
            home.appendingPathComponent(".npm-global/lib/node_modules"),
            home.appendingPathComponent(".local/lib/node_modules"),
            home.appendingPathComponent(".local/opt/node/lib/node_modules"),
            home.appendingPathComponent(".bun/install/global/node_modules")
        ]
        roots += versioned(home.appendingPathComponent(".nvm/versions/node"), ["lib", "node_modules"])
        roots += versioned(home.appendingPathComponent(".local/opt"), ["lib", "node_modules"])
        roots += versioned(home.appendingPathComponent(".volta/tools/image/node"), ["lib", "node_modules"])

        let pattern = try! NSRegularExpression(
            pattern: "([0-9]{10,}-[a-z0-9]+\\.apps\\.googleusercontent\\.com)[\\s\\S]{0,300}?(GOCSPX-[A-Za-z0-9_-]+)")

        for root in roots {
            let pkg = root.appendingPathComponent("@google/gemini-cli")
            guard fm.fileExists(atPath: pkg.path) else { continue }
            guard let walker = fm.enumerator(at: pkg, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let file as URL in walker {
                guard file.pathExtension == "js",
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size < 30_000_000,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let m = pattern.firstMatch(in: text, range: range),
                   let idR = Range(m.range(at: 1), in: text),
                   let scR = Range(m.range(at: 2), in: text) {
                    let c = Client(id: String(text[idR]), secret: String(text[scR]))
                    cached = c
                    return c
                }
            }
        }
        cached = Client?.none
        return nil
    }
}

/// Two places a Google login can already exist on this Mac.
enum GoogleCredentialSource {
    /// gemini-cli writes a plain JSON file.
    static func geminiCLIRefreshToken() -> String? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard let d = try? Data(contentsOf: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["refresh_token"] as? String
    }

    /// Antigravity keeps its login in the login keychain rather than a file —
    /// the SAME item serves both the IDE and the `agy` CLI, so one read covers
    /// both. macOS gates this with a one-time consent prompt.
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
    ///   { "auth_method": …, "id_token": …, "token": { … } }
    /// The OAuth material sits under `token`.
    static func antigravityRefreshToken() -> String? {
        guard let raw = antigravityKeychainBlob() else { return nil }
        let body: String
        if let r = raw.range(of: "go-keyring-base64:") {
            body = String(raw[r.upperBound...])
        } else {
            body = raw
        }
        guard let decoded = Data(base64Encoded: body),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return raw.hasPrefix("1//") ? raw : nil }

        func pluck(_ o: [String: Any]) -> String? {
            for k in ["refresh_token", "refreshToken", "RefreshToken"] {
                if let t = o[k] as? String, !t.isEmpty { return t }
            }
            return nil
        }
        if let t = pluck(root) { return t }
        if let tok = root["token"] as? [String: Any], let t = pluck(tok) { return t }
        for v in root.values {
            if let nested = v as? [String: Any], let t = pluck(nested) { return t }
        }
        return nil
    }
}

struct GoogleAdapterImpl: UsageAdapter {
    func fetch(account: Account) async throws -> FetchedUsage {
        guard let client = GeminiOAuthClient.discover() else {
            throw AdapterError.notImplemented("gemini-cli install not found (its OAuth client is required)")
        }
        guard let refresh = GoogleCredentialSource.antigravityRefreshToken()
                ?? GoogleCredentialSource.geminiCLIRefreshToken() else {
            throw AdapterError.notSignedIn
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

    /// Code Assist meters each model VERSION separately, so buckets are kept
    /// apart rather than collapsed.
    private func loadQuota(token: String) async throws -> FetchedUsage {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "IDE_UNSPECIFIED",
                         "platform": "PLATFORM_UNSPECIFIED",
                         "pluginType": "GEMINI"]
        ])
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw AdapterError.transport("no response") }
        guard http.statusCode == 200 else { throw AdapterError.transport("HTTP \(http.statusCode)") }
        guard let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON")
        }
        var limits: [UsageLimit] = []
        // Bucket shapes vary by account; accept the common spellings.
        for key in ["quotaBuckets", "buckets", "userQuota"] {
            guard let arr = root[key] as? [[String: Any]] else { continue }
            for b in arr {
                let name = (b["modelId"] as? String) ?? (b["name"] as? String) ?? "Quota"
                let used = (b["usedPercent"] as? Double)
                    ?? (b["used"] as? Double).flatMap { u in (b["limit"] as? Double).map { u / $0 * 100 } }
                limits.append(.init(key: name, label: name, percent: used, resetsAt: nil))
            }
        }
        let tier = ((root["currentTier"] as? [String: Any])?["name"] as? String)
        return FetchedUsage(plan: tier, limits: limits)
    }
}
