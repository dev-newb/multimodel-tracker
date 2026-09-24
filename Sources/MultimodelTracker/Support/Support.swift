import Foundation
import Security

enum Support {
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}

/// Tokens never touch UserDefaults — only the Keychain. One item per account
/// id so four subscriptions per vendor stay separate.
enum Keychain {
    struct OpenAICreds { let accessToken: String; let accountId: String?; var refreshToken: String? }

    @MainActor private static let reads = CredentialReadGate()
    private static let keychainQueue = DispatchQueue(label: "com.devnewb.multimodeltracker.keychain")

    struct AccessError: Error, LocalizedError, CustomStringConvertible {
        let status: OSStatus
        let operation: String
        var description: String {
            "Keychain \(operation) failed (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "access unavailable"). Retry Keychain when ready."
        }
        var errorDescription: String? { description }
    }

    /// Refuse to request approval from an invalid/replaced running executable.
    static func validateCaller() throws {
        var code: SecCode?
        let copied = SecCodeCopySelf([], &code)
        guard copied == errSecSuccess, let code else { throw AccessError(status: copied, operation: "signature check") }
        let status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { throw AccessError(status: status, operation: "signature check; quit and reopen the app") }
    }

    @MainActor
    static func cachedData(service: String, account: String) async throws -> Data? {
        try await reads.load("\(service)/\(account)") {
            try await withCheckedThrowingContinuation { continuation in
                keychainQueue.async {
                    do { continuation.resume(returning: try readChecked(service: service, account: account)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    @MainActor
    static func openAICredentialsAsync(for account: UUID) async throws -> OpenAICreds {
        guard let raw = try await cachedData(service: openAIService, account: account.uuidString),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
              let token = obj["access_token"] else { throw AdapterError.notSignedIn }
        return OpenAICreds(accessToken: token, accountId: obj["account_id"], refreshToken: obj["refresh_token"])
    }

    struct AnthropicCreds {
        let accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    @MainActor
    static func anthropicCredentialsAsync(for account: UUID) async throws -> AnthropicCreds {
        guard let raw = try await cachedData(service: anthropicService, account: account.uuidString),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let token = obj["access_token"] as? String else { throw AdapterError.notSignedIn }
        return AnthropicCreds(accessToken: token, refreshToken: obj["refresh_token"] as? String,
                              expiresAt: (obj["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }

    @MainActor
    static func invalidateCache(for account: UUID) {
        for service in [openAIService, anthropicService, googleService] { reads.invalidate("\(service)/\(account)") }
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

    static func store(service: String, account: String, data: Data) throws {
        try validateCaller()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        // Preserve the existing item and its access approvals. Never delete before a save.
        let status = CredentialWritePolicy.save(missingStatus: errSecItemNotFound, update: {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }, add: {
            var added = query; added[kSecValueData as String] = data
            return SecItemAdd(added as CFDictionary, nil)
        })
        guard status == errSecSuccess else { throw AccessError(status: status, operation: "save") }
    }

    static func readChecked(service: String, account: String? = nil) throws -> Data? {
        try validateCaller()
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        if let account { query[kSecAttrAccount as String] = account }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccessError(status: status, operation: "read") }
        return out as? Data
    }

    static func read(service: String, account: String) -> Data? {
        do { return try readChecked(service: service, account: account) }
        catch { record(error); return nil }
    }
    static func readAny(service: String) -> Data? {
        do { return try readChecked(service: service) }
        catch { record(error); return nil }
    }
    private static func record(_ error: Error) {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
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
    /// Google accounts added by browser sign-in keep their own refresh
    /// token here. The Antigravity keychain item and the gemini-cli file
    /// each hold ONE login, so per-account storage is what allows more
    /// than one Google row.
    static let googleService    = "MultimodelTracker.google"

    @MainActor
    static func storeOpenAI(accessToken: String, accountId: String?,
                            refreshToken: String? = nil, for account: UUID) throws {
        var obj = ["access_token": accessToken]
        if let a = accountId { obj["account_id"] = a }
        if let r = refreshToken { obj["refresh_token"] = r }
        let d = try JSONSerialization.data(withJSONObject: obj)
        try store(service: openAIService, account: account.uuidString, data: d)
        reads.seed("\(openAIService)/\(account)", data: d)
    }

    @MainActor
    static func storeAnthropic(accessToken: String, refreshToken: String?,
                               expiresAt: Date?, for account: UUID) throws {
        var obj: [String: Any] = ["access_token": accessToken]
        if let r = refreshToken { obj["refresh_token"] = r }
        if let e = expiresAt { obj["expires_at"] = e.timeIntervalSince1970 }
        let d = try JSONSerialization.data(withJSONObject: obj)
        try store(service: anthropicService, account: account.uuidString, data: d)
        reads.seed("\(anthropicService)/\(account)", data: d)
    }

    @MainActor
    static func storeGoogle(refreshToken: String, for account: UUID) throws {
        let d = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        try store(service: googleService, account: account.uuidString, data: d)
        reads.seed("\(googleService)/\(account)", data: d)
    }

    /// The stored refresh token for a browser-added Google account, or nil
    /// when this row is the machine-credentials import.
    @MainActor
    static func googleRefreshTokenAsync(for account: UUID) async throws -> String? {
        guard let raw = try await cachedData(service: googleService, account: account.uuidString),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String] else { return nil }
        return obj["refresh_token"]
    }

    /// Removing an account must not leave its secrets behind.
    @MainActor
    static func deleteAll(for account: UUID) {
        invalidateCache(for: account)
        for svc in [openAIService, anthropicService, googleService] {
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

/// Adopts Claude Code's existing login for the first Anthropic account —
/// the sibling of CodexCLIImport, with one deliberate difference: the
/// refresh token is NEVER read or used. Claude Code rotates it, and
/// consuming a rotating refresh token from outside can invalidate the CLI's
/// own session. The access token is borrowed while fresh; importing a new
/// copy is explicit so a CLI account switch cannot overwrite this login.
///
/// On macOS the login lives in the keychain item "Claude Code-credentials"
/// (a foreign item — the first read prompts until Always Allow, which
/// sticks against this app's stable signature). ~/.claude/.credentials.json
/// is the fallback shape used on other platforms and older installs.
enum ClaudeCodeImport {
    struct Creds { let accessToken: String; let expiresAt: Date? }

    static func read() -> Creds? {
        let blob = Keychain.readAny(service: "Claude Code-credentials")
            ?? (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")))
        guard let blob,
              let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else { return nil }
        // expiresAt is a JavaScript-style MILLISECOND epoch.
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(accessToken: access, expiresAt: expires)
    }

    /// Fresh enough to be worth storing — a margin past "not yet expired",
    /// so a token about to die doesn't get adopted just in time to fail.
    static func freshCreds() -> Creds? {
        guard let c = read(),
              (c.expiresAt ?? .distantFuture) > Date().addingTimeInterval(120) else { return nil }
        return c
    }
}
