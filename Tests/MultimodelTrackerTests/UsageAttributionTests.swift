import Foundation

@main
struct UsageAttributionTests {
    static func main() async throws {
        let suite = UsageAttributionTests()
        try await suite.testAccountSwitchAndRetryDoNotReassignOrDoubleCount()
        try suite.testMissingIdentityAndNonUsageEventsAreExcluded()
        try suite.testOpenAIUsesDeclaredUnitsWithoutDoubleCounting()
        suite.testResetSurfaceIsUnknownNotZero()
        print("PASS: account switching, organization isolation, retry deduplication, persistence, content exclusion, missing identity, malformed counts, OpenAI units")
    }
    let accountA = "11111111-1111-4111-8111-111111111111"
    let accountB = "22222222-2222-4222-8222-222222222222"
    func payload(account: String?, org: String = "org-a", request: String = "req-1", kind: String = "api_request", tokens: String = "100") throws -> Data {
        var attrs = ["event.name": kind, "organization.id": org, "request_id": request,
                     "model": "claude-test", "input_tokens": tokens, "output_tokens": "20", "cache_read_tokens": "30",
                     "session.id": "same-conversation", "prompt": "must never persist"]
        if let account { attrs["user.account_uuid"] = account }
        let log: [String: Any] = ["timeUnixNano": String(UInt64(Date().timeIntervalSince1970*1e9)),
                                  "attributes": attrs.map { ["key": $0.key, "value": ["stringValue": $0.value]] }]
        return try JSONSerialization.data(withJSONObject: ["resourceLogs": [["scopeLogs": [["logRecords": [log]]]]]])
    }
    func testAccountSwitchAndRetryDoNotReassignOrDoubleCount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let ledger = ClaudeUsageLedger(file: file)
        let a = try payload(account: accountA)
        try await ledger.ingest(a); try await ledger.ingest(a)
        try await ledger.ingest(payload(account: accountB, request: "req-2", tokens: "200"))
        try await ledger.ingest(payload(account: accountA, org: "org-b", request: "req-3", tokens: "500"))
        let reportA = await ledger.report(account: accountA, organization: "org-a")
        let reportB = await ledger.report(account: accountB, organization: "org-a")
        assertEqual(reportA.rows.first?.value, 150)
        assertEqual(reportB.rows.first?.value, 250)
        assertFalse(try String(contentsOf: file, encoding: .utf8).contains("must never persist"))
        let reopened = ClaudeUsageLedger(file: file)
        let restored = await reopened.report(account: accountA, organization: "org-a")
        assertEqual(restored.rows.first?.value, 150)
    }
    func testMissingIdentityAndNonUsageEventsAreExcluded() throws {
        assertTrue(try ClaudeTelemetryParser.parse(payload(account: nil)).isEmpty)
        assertTrue(try ClaudeTelemetryParser.parse(payload(account: accountA, kind: "user_prompt")).isEmpty)
        assertTrue(try ClaudeTelemetryParser.parse(payload(account: accountA, tokens: "-1")).isEmpty)
        assertTrue(try ClaudeTelemetryParser.parse(payload(account: accountA, tokens: "nan")).isEmpty)
    }
    func testResetSurfaceIsUnknownNotZero() {
        let restricted: [String: Any] = ["cedar_ember": ["eligible": false, "ineligible_reason": "surface", "grants": []]]
        assertTrue(ClaudeResetDiscovery.summarize(restricted)?.contains("cannot confirm") == true)
        assertTrue(ClaudeResetDiscovery.summarize(["cedar_ember": NSNull()]) == nil)
        let expired: [String: Any] = ["cedar_ember": ["eligible": true, "grants": [["id":"a", "resets_left":1, "ends_at":"2020-01-01T00:00:00.000Z"]]]]
        assertTrue(ClaudeResetDiscovery.summarize(expired) == nil)
    }
    func testOpenAIUsesDeclaredUnitsWithoutDoubleCounting() throws {
        let raw = #"{"units":"percent","data":[{"attribution":[{"model":"m","value":12.5}],"models":[{"model":"m","credits":12.5}]},{"attribution":[{"model":"m","value":3}]}]}"#
        let report = try OpenAIModelUsage.parse(Data(raw.utf8))
        assertEqual(report.unit, "percent")
        assertEqual(report.rows.first?.value, 15.5)
        assertThrows(try OpenAIModelUsage.parse(Data(#"{"units":"mystery","data":[]}"#.utf8)))
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(a) == \(b)") }
func assertTrue(_ value: Bool) { precondition(value) }
func assertFalse(_ value: Bool) { precondition(!value) }
func assertThrows(_ operation: @autoclosure () throws -> Any) {
    do { _ = try operation(); fatalError("Expected error") } catch { }
}
