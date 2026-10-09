import Foundation

/// Preserve provider-declared disabled windows without presenting them as usable quota.
enum GoogleQuotaSummary {
    static func parse(_ root: [String: Any]) -> [UsageLimit] {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let value = value as? String else { return nil }
            return isoFrac.date(from: value) ?? iso.date(from: value)
        }
        func keyPart(_ text: String) -> String {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
                .split(separator: "-").joined(separator: "-")
        }
        func shortGroup(_ name: String) -> String {
            switch name.lowercased() {
            case "gemini models": return "Gemini"
            case "claude and gpt models": return "Claude/GPT"
            default: return name
            }
        }
        func shortBucket(_ name: String) -> String {
            switch name.lowercased() {
            case "weekly limit remaining": return "weekly"
            case "five hour limit remaining": return "5-hour"
            default: return name
            }
        }
        var limits: [UsageLimit] = []
        let payload = (root["response"] as? [String: Any]) ?? root
        let groups = payload["groups"] as? [[String: Any]] ?? []
        for group in groups {
            let groupName = (group["displayName"] as? String) ?? "Models"
            for bucket in (group["buckets"] as? [[String: Any]] ?? []) {
                let disabled = bucket["disabled"] as? Bool == true
                let remaining = (bucket["remainingFraction"] as? Double)
                    ?? (bucket["remaining"] as? [String: Any])?["remainingFraction"] as? Double
                let validRemaining = remaining.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
                guard disabled || validRemaining != nil else { continue }
                let bucketName = (bucket["displayName"] as? String) ?? "Limit"
                let bucketId = (bucket["bucketId"] as? String) ?? keyPart(bucketName)
                let key = "google-summary-\(keyPart(groupName))-\(keyPart(bucketId))"
                limits.append(UsageLimit(key: key,
                                         label: "\(shortGroup(groupName)) · \(shortBucket(bucketName))",
                                         percent: disabled ? nil : validRemaining.map { (1 - $0) * 100 },
                                         resetsAt: disabled ? nil : date(bucket["resetTime"]),
                                         unavailableReason: disabled ? "Google has disabled this quota window. Other limits, including the weekly quota, still apply." : nil))
            }
        }
        return limits
    }
}
