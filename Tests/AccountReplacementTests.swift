import Foundation

@main
struct AccountReplacementTests {
    static func main() throws {
        let old = Account(provider: .google, label: "old@example.com", nickname: "Work", plan: "Pro",
                          limits: [UsageLimit(key: "weekly", label: "Weekly", percent: 70, resetsAt: nil)],
                          lastRefreshed: Date())
        var slot = old
        slot.replaceLogin(email: "new@example.com")
        precondition(slot.id == old.id && slot.nickname == "Work")
        precondition(slot.label == "new@example.com" && slot.credentialRevision != old.credentialRevision)
        precondition(slot.limits.isEmpty && slot.plan == nil && slot.lastRefreshed == nil)
        precondition(!slot.applyUsage(from: old), "An old in-flight refresh overwrote the new account")
        precondition(slot.label == "new@example.com")
        var fresh = slot
        fresh.limits = [UsageLimit(key: "weekly", label: "Weekly", percent: 15, resetsAt: nil)]
        slot.nickname = "Renamed during refresh"
        precondition(slot.applyUsage(from: fresh) && slot.worstPercent == 15)
        precondition(slot.nickname == "Renamed during refresh")
        let saved = try JSONEncoder().encode(slot)
        precondition(!String(decoding: saved, as: UTF8.self).contains("credentialRevision"))
        let restored = try JSONDecoder().decode(Account.self, from: saved)
        precondition(restored.label == slot.label && restored.id == slot.id && restored.credentialRevision != slot.credentialRevision)
        precondition(old.matches(provider: .google, email: " OLD@example.com "))
        precondition(!old.matches(provider: .anthropic, email: "old@example.com"))
        precondition(!old.matches(provider: .google, email: "different@example.com"))
        precondition(!Account(provider: .google, label: "Google account").matches(provider: .google, email: "Google account"))
        var known = slot
        known.authentication = AuthenticationInfo(source: .codexCLI, accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), canRefresh: false)
        known.needsReconnect = true
        let encoded = try JSONEncoder().encode(known)
        let decoded = try JSONDecoder().decode(Account.self, from: encoded)
        precondition(decoded.authSource == .codexCLI && decoded.needsReconnect == true)
        precondition(decoded.authenticationTooltip.contains("cannot renew") == false) // reconnect takes priority
        precondition(decoded.authenticationTooltip.contains("Reconnect"))
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyJSON.removeValue(forKey: "authentication"); legacyJSON.removeValue(forKey: "needsReconnect")
        let legacy = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacy.id == known.id && legacy.authentication == nil && legacy.needsReconnect == nil)
        precondition(AuthenticationInfo.jwtExpiry("opaque-token") == nil)
        let body = Data(#"{"exp":2000000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        precondition(AuthenticationInfo.jwtExpiry("header." + body + ".signature") == Date(timeIntervalSince1970: 2_000_000_000))
        precondition(AntigravityServiceRoute.host(in: "server --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com --other ignored") == .daily)
        precondition(AntigravityServiceRoute.host(in: "server --cloud_code_endpoint=https://cloudcode-pa.googleapis.com/") == .production)
        precondition(AntigravityServiceRoute.host(in: "server --cloud_code_endpoint https://cloudcode-pa.googleapis.com.attacker.invalid") == nil)
        precondition(AntigravityServiceRoute.host(in: "server --cloud_code_endpoint http://cloudcode-pa.googleapis.com") == nil)
        precondition(AntigravityServiceRoute.host(in: "server --unrelated https://daily-cloudcode-pa.googleapis.com") == nil)
        print("PASS: account replacement, late-response isolation, slot/nickname preservation, persisted account compatibility")
    }
}
