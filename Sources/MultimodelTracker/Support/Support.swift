import Foundation

enum Support {
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}

/// Tokens never touch UserDefaults — only the Keychain. One item per account
/// id so four subscriptions per vendor stay separate.
enum Keychain {
    struct OpenAICreds { let accessToken: String; let accountId: String? }

    static func openAICredentials(for account: UUID) throws -> OpenAICreds {
        guard let raw = read(service: "MultimodelTracker.openai", account: account.uuidString),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
              let token = obj["access_token"] else { throw AdapterError.notSignedIn }
        return OpenAICreds(accessToken: token, accountId: obj["account_id"])
    }

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

    static func storeOpenAI(accessToken: String, accountId: String?, for account: UUID) {
        var obj = ["access_token": accessToken]
        if let a = accountId { obj["account_id"] = a }
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        store(service: openAIService, account: account.uuidString, data: d)
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
