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
    struct Client: Equatable { let id: String; let secret: String }
    private static var cachedCandidates: [Client]?
    /// The pair that last exchanged successfully, tried first from then on.
    static var winner: Client?

    /// EVERY id x secret pair found in Antigravity's binaries, not just the
    /// first. Both appear more than once and the FIRST id in the binary is not
    /// the one that works (884354919052… fails; 1071006060591… succeeds), so
    /// picking one is a coin flip — the reference tools cycle candidates for
    /// exactly this reason. Ordering puts any known-good pair first.
    static func candidates() -> [Client] {
        if let c = cachedCandidates {
            return winner.map { w in [w] + c.filter { $0 != w } } ?? c
        }
        let fm = FileManager.default
        let sources = [
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy"),
        ]
        let idPattern = try! NSRegularExpression(
            pattern: "[0-9]{10,}-[a-z0-9]{20,}\\.apps\\.googleusercontent\\.com")
        // Secrets sit back to back with no separator, so bound the length
        // rather than letting the match run into the next one.
        let secretPattern = try! NSRegularExpression(pattern: "GOCSPX-[A-Za-z0-9_-]{28}")

        var ids: [String] = [], secrets: [String] = []
        for url in sources {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            for m in idPattern.matches(in: text, range: range) {
                if let r = Range(m.range, in: text) { ids.append(String(text[r])) }
            }
            for m in secretPattern.matches(in: text, range: range) {
                if let r = Range(m.range, in: text) { secrets.append(String(text[r])) }
            }
            if !ids.isEmpty && !secrets.isEmpty { break }
        }
        var seenID = Set<String>(), seenSecret = Set<String>()
        let uniqueIDs = ids.filter { seenID.insert($0).inserted }
        let uniqueSecrets = secrets.filter { seenSecret.insert($0).inserted }
        let all = uniqueIDs.flatMap { id in uniqueSecrets.map { Client(id: id, secret: $0) } }
        cachedCandidates = all
        return winner.map { w in [w] + all.filter { $0 != w } } ?? all
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

/// Which Google surface to read.
enum GoogleAuthMode: Int, CaseIterable {
    /// Antigravity's per-model quota — what the IDE and `agy` actually meter.
    case antigravity = 0
    /// The older Code Assist buckets. Kept because gemini-cli users still
    /// have them, and they're the only thing a CLI-only login exposes.
    case codeAssist = 1

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity (per-model)"
        case .codeAssist:  return "Gemini Code Assist (legacy)"
        }
    }
}

struct GoogleAdapterImpl: UsageAdapter {
    var mode: GoogleAuthMode = .antigravity

    /// The project id comes from loadCodeAssist and rarely changes; holding it
    /// avoids a second round trip on every poll.
    private static var cachedProject: String?
    /// Last good per-model read, held so a transient 403 shows the previous
    /// numbers (with the popover's "stale" chip) instead of an error row.
    private static var lastGood: (at: Date, usage: FetchedUsage)?

    func fetch(account: Account) async throws -> FetchedUsage {
        guard let blob = await GoogleCredentialSource.antigravityTokenBlob()
                ?? GoogleCredentialSource.geminiCLITokenBlob() else {
            throw AdapterError.notSignedIn
        }
        // Always mint a fresh access token. The stored one expires roughly
        // hourly and an idle agy does not rotate it, so trusting it is the
        // main cause of spurious 401s.
        var access: String?
        if let refresh = blob.refreshToken {
            for client in GeminiOAuthClient.candidates() {
                if let t = try? await exchange(refresh: refresh, client: client) {
                    GeminiOAuthClient.winner = client
                    access = t
                    break
                }
            }
        }
        // Only fall back to the stored token if it is genuinely still live.
        if access == nil, let token = blob.accessToken,
           blob.expiry.map({ $0 > Date().addingTimeInterval(60) }) ?? false {
            access = token
        }
        guard let access else { throw AdapterError.notSignedIn }

        switch mode {
        case .codeAssist:  return try await loadLegacyQuota(token: access)
        case .antigravity: return try await loadModelQuota(token: access)
        }
    }

    private func exchange(refresh: String, client: GeminiOAuthClient.Client) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = ("client_id=\(client.id)&client_secret=\(client.secret)"
                        + "&refresh_token=\(refresh)&grant_type=refresh_token").data(using: .utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["access_token"] as? String else { throw AdapterError.notSignedIn }
        return t
    }

    private static let metadata: [String: String] = [
        "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"
    ]

    private func call(_ method: String, body: [String: Any], token: String,
                      agent: String?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string:
            "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Identifying as "antigravity" is REQUIRED for fetchAvailableModels —
        // URLSession's default agent gets a flat 403, verified by sending the
        // identical request with and without it. It also changes what
        // retrieveUserQuota returns (24 model rows instead of 4 Code Assist
        // buckets), which is why the legacy mode deliberately omits it: the
        // two modes would otherwise report the same thing.
        if let agent { req.setValue(agent, forHTTPHeaderField: "User-Agent") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw AdapterError.transport("no response") }
        if http.statusCode == 401 { throw AdapterError.notSignedIn }
        guard http.statusCode == 200 else { throw AdapterError.transport("\(method) HTTP \(http.statusCode)") }
        guard let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON from \(method)")
        }
        return root
    }

    /// Antigravity's real metering. `fetchAvailableModels` needs the caller's
    /// **project id in the BODY** — that, not any header, is what separates a
    /// 200 from a 403; a bare call fails no matter what metadata is attached.
    /// The project comes from loadCodeAssist's `cloudaicompanionProject`.
    private func loadModelQuota(token: String) async throws -> FetchedUsage {
        do {
            if Self.cachedProject == nil {
                let lca = try await call("loadCodeAssist", body: ["metadata": Self.metadata],
                                        token: token, agent: "antigravity")
                if let s = lca["cloudaicompanionProject"] as? String { Self.cachedProject = s }
                else if let o = lca["cloudaicompanionProject"] as? [String: Any] {
                    Self.cachedProject = o["id"] as? String
                }
            }
            var body: [String: Any] = [:]
            if let p = Self.cachedProject { body["project"] = p }
            let root = try await call("fetchAvailableModels", body: body,
                                      token: token, agent: "antigravity")
            let usage = try Self.parseModels(root)
            Self.lastGood = (Date(), usage)
            return usage
        } catch {
            // A stale project id 403s; drop it so the next poll re-derives one.
            Self.cachedProject = nil
            if let held = Self.lastGood, Date().timeIntervalSince(held.at) < 3600 {
                return held.usage
            }
            throw error
        }
    }

    /// Models that share a pool report the SAME remainingFraction AND reset —
    /// 24 rows would be 22 duplicates. Group by that pair and name each group
    /// after the families inside it, so the row count follows how Google
    /// actually meters rather than how many model ids it lists.
    /// Models Antigravity routes but Google does not make: Claude, GPT-OSS,
    /// and anything else that isn't a Gemini/Gemma/Imagen family name.
    static func isForeign(_ id: String) -> Bool {
        let s = id.lowercased()
        if s.contains("claude") || s.contains("gpt") || s.contains("llama")
            || s.contains("mistral") || s.contains("qwen") || s.contains("deepseek") {
            return true
        }
        return !(s.contains("gemini") || s.contains("gemma") || s.contains("imagen"))
    }

    static func parseModels(_ root: [String: Any]) throws -> FetchedUsage {
        var entries: [(id: String, quota: [String: Any])] = []
        if let dict = root["models"] as? [String: Any] {
            for (id, v) in dict {
                if let m = v as? [String: Any], let q = m["quotaInfo"] as? [String: Any] {
                    entries.append((id, q))
                }
            }
        } else if let arr = root["models"] as? [[String: Any]] {
            for m in arr {
                if let id = (m["modelId"] as? String) ?? (m["name"] as? String),
                   let q = m["quotaInfo"] as? [String: Any] { entries.append((id, q)) }
            }
        }
        // Editor-internal pools, not something a user spends deliberately.
        entries = entries.filter { !$0.id.hasPrefix("chat_") && !$0.id.hasPrefix("tab_")
                                   && !$0.id.hasPrefix("rev") }
        // This is the GOOGLE section: drop every non-Google model BEFORE
        // grouping. Filtering whole pools instead let foreign models ride
        // along whenever their pool happened to match Gemini's numbers —
        // right after a reset everything reads 1.0, which merged all 20
        // models into one row labelled "Claude · GPT-OSS · Gemini".
        entries = entries.filter { !Self.isForeign($0.id) }
        guard !entries.isEmpty else { throw AdapterError.transport("no models with quota") }

        let iso = ISO8601DateFormatter()
        var groups: [String: (pct: Double, reset: Date?, families: Set<String>, n: Int)] = [:]
        for e in entries {
            guard let remaining = e.quota["remainingFraction"] as? Double else { continue }
            let resetStr = (e.quota["resetTime"] as? String) ?? ""
            let key = "\(remaining)|\(resetStr)"
            let family = "Gemini"
            var g = groups[key] ?? (pct: (1 - remaining) * 100,
                                    reset: resetStr.isEmpty ? nil : iso.date(from: resetStr),
                                    families: [], n: 0)
            g.families.insert(family); g.n += 1
            groups[key] = g
        }
        let limits = groups
            .sorted { ($0.value.pct, $0.key) > ($1.value.pct, $1.key) }
            .map { key, g -> UsageLimit in
                let name = g.families.sorted().joined(separator: " · ")
                return UsageLimit(key: key,
                                  label: "\(name) · \(g.n) model\(g.n == 1 ? "" : "s")",
                                  percent: g.pct, resetsAt: g.reset)
            }
        return FetchedUsage(plan: "Antigravity", limits: limits)
    }

    /// The older Code Assist buckets: `retrieveUserQuota` with an empty body,
    /// one bucket per model. Agent usage never touches these, which is why
    /// they read 0% while Antigravity work is in flight.
    private func loadLegacyQuota(token: String) async throws -> FetchedUsage {
        let root = try await call("retrieveUserQuota", body: [:], token: token, agent: nil)
        guard let buckets = root["buckets"] as? [[String: Any]] else {
            throw AdapterError.transport("no quota buckets in response")
        }
        let iso = ISO8601DateFormatter()
        let limits: [UsageLimit] = buckets.compactMap { b in
            guard let model = b["modelId"] as? String else { return nil }
            let used = (b["remainingFraction"] as? Double).map { (1 - $0) * 100 }
            let type = (b["tokenType"] as? String) ?? ""
            let label = type == "REQUESTS" ? model : "\(model) · \(type.lowercased())"
            return UsageLimit(key: "\(model)_\(type)", label: label, percent: used,
                              resetsAt: (b["resetTime"] as? String).flatMap { iso.date(from: $0) })
        }
        guard !limits.isEmpty else { throw AdapterError.transport("quota response had no models") }
        return FetchedUsage(plan: "Code Assist", limits: limits)
    }
}
