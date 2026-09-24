import Foundation

@main
struct UsageAttributionTests {
    static func main() async throws {
        let suite = UsageAttributionTests()
        try await suite.testAccountSwitchAndRetryDoNotReassignOrDoubleCount()
        try suite.testMissingIdentityAndNonUsageEventsAreExcluded()
        try suite.testOpenAIUsesDeclaredUnitsWithoutDoubleCounting()
        try suite.testGoogleModelQuotaDetails()
        try suite.testGoogleCatalogAvailabilityDoesNotOverrideQuota()
        try suite.testOpenAIModelFallbackAndEmptyActivity()
        try suite.testOpenAIFreshnessAndDateRange()
        print("PASS: account switching, organization isolation, retry deduplication, persistence, content exclusion, missing identity, malformed counts, OpenAI units")
    }
    let accountA = "11111111-1111-4111-8111-111111111111"
    let accountB = "22222222-2222-4222-8222-222222222222"
    let analyticsNow = ISO8601DateFormatter().date(from: "2026-09-23T15:00:00Z")!
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
    func testGoogleModelQuotaDetails() throws {
        let raw = #"{"models":{"gemini-test":{"displayName":"Gemini Test","quotaInfo":{"remainingFraction":0.25}},"claude-test":{"quotaInfo":{"remainingFraction":0}},"gpt-test":{"quotaInfo":{"remainingFraction":1}},"chat_internal":{"quotaInfo":{"remainingFraction":1}},"unknown":{},"invalid":{"quotaInfo":{"remainingFraction":2}}}}"#
        let root = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        let report = try GoogleModelDetails.parse(root)
        assertEqual(report.unit, "quotaPercent")
        assertEqual(report.rows.count, 3)
        assertEqual(report.rows.first { $0.id == "gemini-test" }?.value, 75)
        assertEqual(report.rows.first { $0.id == "claude-test" }?.value, 100)
        assertEqual(report.rows.first { $0.id == "gpt-test" }?.value, 0)
        let array = try GoogleModelDetails.parse(["models": [["modelId": "gemini-test", "quotaInfo": ["remainingFraction": 0.25]]]])
        assertEqual(array.rows.first?.value, 75)
    }
    func testGoogleCatalogAvailabilityDoesNotOverrideQuota() throws {
        let models: [String: Any] = ["models": ["gemini-test": ["displayName": "Gemini Test", "quotaInfo": ["remainingFraction": 1.0]]]]
        let quota: [String: Any] = ["buckets": [["modelId": "gemini-test", "tokenType": "REQUESTS", "remainingFraction": 0.25],
                                                ["modelId": "unknown", "resetTime": "2026-09-24T00:00:00Z"]]]
        let report = try GoogleModelDetails.parseVerified(models: models, quota: quota)
        assertEqual(report.rows.count, 1)
        assertEqual(report.rows.first?.value, 75)
        assertEqual(report.rows.first?.model, "Gemini Test")
        assertThrows(try GoogleModelDetails.parseVerified(models: models, quota: [:]))
        assertThrows(try GoogleModelDetails.parseVerified(models: models, quota: ["buckets": [["modelId": "m", "remainingFraction": 2.0]]]))
    }
    func testOpenAIModelFallbackAndEmptyActivity() throws {
        let raw = #"{"units":"percent","data":[{"date":"2026-09-01","attribution":[],"models":[{"model":"m","speed":"fast","credits":3},{"model":"m","speed":"standard","credits":2},{"model":"zero","credits":0},{"model":"bad","credits":-1}]}]}"#
        let report = try OpenAIModelUsage.parse(Data(raw.utf8), now: analyticsNow)
        assertEqual(report.rows.count, 1)
        assertEqual(report.rows.first?.value, 5)
        assertTrue(report.summary?.contains("2026-09-01") == true)
        let empty = try OpenAIModelUsage.parse(Data(#"{"units":"tokens","data":[]}"#.utf8))
        assertTrue(empty.rows.isEmpty)
        assertTrue(empty.emptyMessage.contains("no model activity"))
    }
    func testOpenAIUsesDeclaredUnitsWithoutDoubleCounting() throws {
        let raw = #"{"units":"percent","data":[{"date":"2026-09-22","attribution":[{"model":"m","value":12.5}],"models":[{"model":"m","credits":12.5}]},{"date":"2026-09-23","attribution":[{"model":"m","value":3}]}]}"#
        let report = try OpenAIModelUsage.parse(Data(raw.utf8), now: analyticsNow)
        assertEqual(report.unit, "percent")
        assertEqual(report.rows.first?.value, 15.5)
        assertThrows(try OpenAIModelUsage.parse(Data(#"{"units":"mystery","data":[]}"#.utf8)))
    }
    func testOpenAIFreshnessAndDateRange() throws {
        let raw = #"{"units":"percent","data":[{"date":"2026-08-01","attribution":[{"model":"m","value":100}]},{"date":"2026-09-15","attribution":[{"model":"m","value":5}]},{"date":"2026-09-23","attribution":[],"models":[{"model":"m","credits":0}]},{"date":"2026-09-25","attribution":[{"model":"m","value":500}]}]}"#
        let report = try OpenAIModelUsage.parse(Data(raw.utf8), now: analyticsNow)
        assertEqual(report.rows.first?.value, 5)
        assertTrue(report.summary?.contains("2026-09-15") == true)
        assertTrue(report.freshnessWarning?.contains("2026-09-15") == true)
        let fresh = try OpenAIModelUsage.parse(Data(#"{"units":"percent","data":[{"date":"2026-09-23","attribution":[{"model":"m","value":2}]}]}"#.utf8), now: analyticsNow)
        assertTrue(fresh.freshnessWarning == nil)
        assertThrows(try OpenAIModelUsage.parse(Data(#"{"units":"percent","data":[{"date":"invalid","models":[]}]}"#.utf8), now: analyticsNow))
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(a) == \(b)") }
func assertTrue(_ value: Bool) { precondition(value) }
func assertFalse(_ value: Bool) { precondition(!value) }
func assertThrows(_ operation: @autoclosure () throws -> Any) {
    do { _ = try operation(); fatalError("Expected error") } catch { }
}
