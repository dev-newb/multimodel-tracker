import Foundation

enum Support {
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}

/// Tokens never touch UserDefaults — only the Keychain. One item per account
/// id so four subscriptions per vendor stay separate.
enum Keychain {
    struct OpenAICreds { let accessToken: String; let accountId: String?; var refreshToken: String? }

    /// Per-launch cache. The keychain is read once per account per run; every
    /// later poll is served from memory, so a poll can never trigger a
    /// password prompt.
    private static var openAICache: [UUID: OpenAICreds] = [:]

    /// `SecItemCopyMatching` blocks for as long as the password panel is up.
    /// Called straight from the @MainActor store that froze the entire UI —
    /// no popover, no Accounts window — until the prompt was answered. Only
    /// the blocking call goes to the background queue; the cache stays on the
    /// main actor, so it needs no locking of its own.
    @MainActor
    static func openAICredentialsAsync(for account: UUID) async throws -> OpenAICreds {
        if let hit = openAICache[account] { return hit }
        let raw: Data? = await withCheckedContinuation { cont in
            keychainQueue.async {
                cont.resume(returning: read(service: "MultimodelTracker.openai",
                                            account: account.uuidString))
            }
        }
        guard let raw,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
              let token = obj["access_token"] else { throw AdapterError.notSignedIn }
        let creds = OpenAICreds(accessToken: token, accountId: obj["account_id"],
                                refreshToken: obj["refresh_token"])
        openAICache[account] = creds
        return creds
    }

    private static let keychainQueue = DispatchQueue(label: "com.devnewb.multimodeltracker.keychain")

    struct AnthropicCreds {
        let accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    private static var anthropicCache: [UUID: AnthropicCreds] = [:]

    /// Same contract as the OpenAI read: one blocking keychain hit per
    /// account per launch, everything after that from memory. Throwing
    /// notSignedIn here is also the router — an account with no stored OAuth
    /// item is a legacy cookie-jar login (a MISSING item answers instantly
    /// and silently; only present items with foreign ACLs can prompt).
    @MainActor
    static func anthropicCredentialsAsync(for account: UUID) async throws -> AnthropicCreds {
        if let hit = anthropicCache[account] { return hit }
        let raw: Data? = await withCheckedContinuation { cont in
            keychainQueue.async {
                cont.resume(returning: read(service: anthropicService,
                                            account: account.uuidString))
            }
        }
        guard let raw,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let token = obj["access_token"] as? String else { throw AdapterError.notSignedIn }
        let creds = AnthropicCreds(accessToken: token,
                                   refreshToken: obj["refresh_token"] as? String,
                                   expiresAt: (obj["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        anthropicCache[account] = creds
        return creds
    }

    static func invalidateCache(for account: UUID) {
        openAICache[account] = nil
        anthropicCache[account] = nil
    }

    /// Every account UUID that still has a stored token for `service`. The
    /// keychain outlives the accounts list, so this is what makes recovery
    /// possible.
    private static func accountIDs(service: String) -> [UUID] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init) }
    }

    static func openAIAccountIDs() -> [UUID] { accountIDs(service: openAIService) }
    static func anthropicAccountIDs() -> [UUID] { accountIDs(service: anthropicService) }

    static func store(service: String, account: String, data: Data) {
        delete(service: service, account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: data]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func read(service: String, account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func delete(service: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

extension Keychain {
    static let openAIService    = "MultimodelTracker.openai"
    static let anthropicService = "MultimodelTracker.anthropic"

    static func storeOpenAI(accessToken: String, accountId: String?,
                            refreshToken: String? = nil, for account: UUID) {
        invalidateCache(for: account)
        var obj = ["access_token": accessToken]
        if let a = accountId { obj["account_id"] = a }
        if let r = refreshToken { obj["refresh_token"] = r }
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        store(service: openAIService, account: account.uuidString, data: d)
    }

    static func storeAnthropic(accessToken: String, refreshToken: String?,
                               expiresAt: Date?, for account: UUID) {
        invalidateCache(for: account)
        var obj: [String: Any] = ["access_token": accessToken]
        if let r = refreshToken { obj["refresh_token"] = r }
        if let e = expiresAt { obj["expires_at"] = e.timeIntervalSince1970 }
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        store(service: anthropicService, account: account.uuidString, data: d)
    }

    /// Removing an account must not leave its secrets behind.
    static func deleteAll(for account: UUID) {
        for svc in [openAIService, anthropicService] {
            delete(service: svc, account: account.uuidString)
        }
    }
}

/// Adopts the Codex CLI's existing login instead of making the user complete
/// OAuth again for their first OpenAI account. Shape of ~/.codex/auth.json:
///   { "tokens": { "access_token": ..., "id_token": ..., "account_id": ... } }
/// The account id is also recoverable from the id_token's
/// `https://api.openai.com/auth` claim when it isn't stored directly.
enum CodexCLIImport {
    struct Creds { let accessToken: String; let accountId: String?; let email: String? }

    static func read() -> Creds? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }

        var accountId = tokens["account_id"] as? String
        var email: String?
        if let idToken = tokens["id_token"] as? String {
            let claims = decodeJWT(idToken)
            if accountId == nil {
                let auth = claims["https://api.openai.com/auth"] as? [String: Any]
                accountId = (auth?["chatgpt_account_id"] as? String) ?? (claims["sub"] as? String)
            }
            email = claims["email"] as? String
        }
        return Creds(accessToken: access, accountId: accountId, email: email)
    }

    private static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }
}
