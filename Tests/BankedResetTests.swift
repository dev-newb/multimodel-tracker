import Foundation

@main
struct BankedResetTests {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
        let payload = Data(#"{"available_count":4,"credits":[{"id":"later","status":"available","expires_at":"2026-10-20T12:00:00Z"},{"id":"first","status":"available","expires_at":"2026-10-10T12:00:00Z"},{"id":"second","status":"available","expires_at":"2026-10-10T12:00:00.000Z"},{"id":"unknown","status":"available","expires_at":null},{"id":"used","status":"redeemed","expires_at":"2026-10-09T13:00:00Z"},{"id":"expired","status":"expired","expires_at":"2026-10-08T00:00:00Z"},{"id":"first","status":"available","expires_at":"2026-10-10T12:00:00Z"}]}"#.utf8)
        let details = try BankedResetDetails.parse(payload, now: now)
        precondition(details.availableCount == 4 && details.expirations.count == 3)
        precondition(details.expirations == details.expirations.sorted())
        precondition(details.expiresSoon(at: now))
        let tip = details.tooltip(at: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        precondition(tip.contains("2 resets:") && tip.contains("1 reset: expiration not provided"))
        precondition(tip.range(of: "Oct 10")!.lowerBound < tip.range(of: "Oct 20")!.lowerBound)
        precondition(!details.expiresSoon(at: now.addingTimeInterval(2 * 86400)))
        precondition(details.tooltip(at: now.addingTimeInterval(2 * 86400)).contains("expired; awaiting refresh"))
        let deadline = now.addingTimeInterval(BankedResetDetails.warningInterval)
        precondition(BankedResetDetails(availableCount: 1, expirations: [deadline], checkedAt: now).expiresSoon(at: now))
        precondition(!BankedResetDetails(availableCount: 1, expirations: [deadline.addingTimeInterval(1)], checkedAt: now).expiresSoon(at: now))
        precondition(!BankedResetDetails(availableCount: 1, expirations: [now], checkedAt: now).expiresSoon(at: now))
        var failed = details; failed.lookupFailed = true
        precondition(!failed.expiresSoon(at: now) && failed.tooltip(at: now).contains("could not be retrieved"))
        let zero = try BankedResetDetails.parse(Data(#"{"available_count":0,"credits":[]}"#.utf8), now: now)
        precondition(zero.tooltip(at: now) == "No banked resets available." && !zero.expiresSoon(at: now))
        for bad in [#"{}"#, #"{"available_count":-1,"credits":[]}"#, #"{"available_count":0,"credits":[{"status":"available","expires_at":"2026-10-10T12:00:00Z"}]}"#] {
            do { _ = try BankedResetDetails.parse(Data(bad.utf8)); preconditionFailure("Accepted malformed credits") }
            catch {}
        }
        let row = UsageLimit(key: "resets", label: "Banked resets · 4", percent: nil, resetsAt: nil, bankedResetDetails: details)
        let restored = try JSONDecoder().decode(UsageLimit.self, from: JSONEncoder().encode(row))
        precondition(restored == row)
        let old = try JSONDecoder().decode(UsageLimit.self, from: Data(#"{"key":"resets","label":"Banked resets · 3"}"#.utf8))
        precondition(old.bankedResetDetails == nil)
        print("PASS: expiry parsing, grouping, ordering, status filtering, partial/malformed data, glow boundary, and saved-account compatibility")
    }
}
