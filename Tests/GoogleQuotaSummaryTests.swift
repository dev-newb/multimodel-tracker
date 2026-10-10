import Foundation

@main
struct GoogleQuotaSummaryTests {
    static func main() throws {
        // Live response shape: a depleted weekly pool disables its five-hour window.
        let root: [String: Any] = ["groups": [["displayName": "Claude and GPT models", "buckets": [
            ["bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "remainingFraction": 0.0],
            ["bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "remainingFraction": 1.0, "disabled": true]
        ]]]]
        let limits = GoogleQuotaSummary.parse(root)
        precondition(limits.count == 2)
        precondition(limits[0].percent == 100)
        precondition(limits[1].label == "Claude/GPT · 5-hour")
        precondition(limits[1].percent == nil && limits[1].resetText == "Unavailable")
        precondition(limits[1].unavailableReason != nil && limits[1].resetsAt == nil)
        let restored = try JSONDecoder().decode([UsageLimit].self, from: JSONEncoder().encode(limits))
        precondition(restored == limits)
        let legacy = try JSONDecoder().decode(UsageLimit.self, from: Data(#"{"key":"old","label":"Weekly","percent":20}"#.utf8))
        precondition(legacy.unavailableReason == nil && legacy.percent == 20)
        let enabled = GoogleQuotaSummary.parse(["response": ["groups": [["displayName": "Claude and GPT models", "buckets": [
            ["bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "remainingFraction": 0.75],
            ["bucketId": "invalid", "remainingFraction": 2.0],
            ["bucketId": "missing"]
        ]]]]])
        precondition(enabled.count == 1 && enabled[0].percent == 25 && enabled[0].unavailableReason == nil)
        precondition(enabled[0].key == limits[1].key)
        let disabledWithoutAmount = GoogleQuotaSummary.parse(["groups": [["buckets": [["bucketId": "disabled", "disabled": true]]]]])
        precondition(disabledWithoutAmount.count == 1 && disabledWithoutAmount[0].percent == nil)
        print("PASS: disabled quota visibility, enabled quota recovery, invalid values, and saved-data compatibility")
    }
}
