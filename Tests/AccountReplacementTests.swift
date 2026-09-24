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
        print("PASS: account replacement, late-response isolation, slot/nickname preservation, persisted account compatibility")
    }
}
