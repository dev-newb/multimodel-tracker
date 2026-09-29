import Foundation

@main
struct UsageAttributionTests {
    static func main() async throws {
        let suite = UsageAttributionTests()
        try suite.testOpenAIUsesDeclaredUnitsWithoutDoubleCounting()
        try suite.testGoogleModelQuotaDetails()
        try suite.testGoogleIdentityAndDeclaredPools()
        try suite.testGoogleCatalogAvailabilityDoesNotOverrideQuota()
        try suite.testOpenAIModelFallbackAndEmptyActivity()
        try suite.testOpenAIFreshnessAndDateRange()
        print("PASS: OpenAI units, fallback, empty and freshness; Google model quota, declared pools, catalog-vs-quota")
    }
    let analyticsNow = ISO8601DateFormatter().date(from: "2026-09-23T15:00:00Z")!
    func testGoogleIdentityAndDeclaredPools() throws {
        let models: [String: Any] = ["models": ["variant-a": ["displayName": "Gemini Same"], "variant-b": ["displayName": "Gemini Same"]]]
        let bucket: [String: Any] = ["modelId": "variant-a", "tokenType": "WTUS", "remainingFraction": 0.7]
        let report = try GoogleModelDetails.parseVerified(models: models, quota: ["buckets": [bucket, bucket,
            ["modelId": "variant-b", "tokenType": "WTUS", "remainingFraction": 0.7]]])
        assertEqual(report.rows.count, 2)
        assertTrue(report.rows[0].id != report.rows[1].id)
        assertTrue(report.rows[0].caption != report.rows[1].caption)
        let groups = try GoogleModelDetails.parseGroups(["response": ["groups": [
            ["displayName": "Gemini Models", "buckets": [
                ["bucketId": "weekly", "displayName": "Weekly Limit Remaining", "remainingFraction": 0.6],
                ["bucketId": "5h", "displayName": "Five Hour Limit Remaining", "remainingFraction": 0.6],
                ["bucketId": "missing", "displayName": "Missing"],
                ["bucketId": "disabled", "displayName": "Disabled", "remainingFraction": 0.0, "disabled": true]]],
            ["displayName": "Claude and GPT models", "buckets": [
                ["bucketId": "weekly", "displayName": "Weekly Limit Remaining", "remainingFraction": 0.6]]]
        ]]])
        assertEqual(groups.count, 2) // equal amounts do not merge groups
        assertEqual(groups[0].rows.count, 2) // equal amounts do not merge windows
        assertEqual(groups[0].rows[0].value, 40)
        assertThrows(try GoogleModelDetails.parseGroups(["groups": []]))
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
