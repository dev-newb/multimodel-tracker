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
