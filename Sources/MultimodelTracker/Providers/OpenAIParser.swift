import Foundation

/// Shape confirmed against the live endpoint:
///   rate_limit.primary_window { used_percent, reset_at }
///   additional_rate_limits[] { limit_name, rate_limit.primary_window }
///   rate_limit_reset_credits { available_count }   (counts only, no expiry)
enum OpenAIParser {
    static func parse(_ data: Data) throws -> FetchedUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON")
        }
        var limits: [UsageLimit] = []

        func window(_ dict: [String: Any]?) -> (Double, Date?)? {
            guard let w = dict?["primary_window"] as? [String: Any],
                  let pct = w["used_percent"] as? Double else { return nil }
            let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return (pct, reset)
        }

        if let (pct, reset) = window(root["rate_limit"] as? [String: Any]) {
            limits.append(.init(key: "codex", label: "Codex · weekly", percent: pct, resetsAt: reset))
        }
        for extra in (root["additional_rate_limits"] as? [[String: Any]] ?? []) {
            guard let (pct, reset) = window(extra["rate_limit"] as? [String: Any]) else { continue }
            let name = (extra["limit_name"] as? String) ?? "Additional"
            limits.append(.init(key: name.lowercased(), label: "\(name) · weekly",
                                percent: pct, resetsAt: reset))
        }
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            let c = root["rate_limit_reset_credits"]
            FileHandle.standardError.write("openai reset_credits raw: \(String(describing: c))\n".data(using: .utf8)!)
        }
        // Show the banked-reset count whenever the field exists — including 0.
        // Hiding the row at zero made "resets aren't showing" indistinguishable
        // from "you have none".
        if let credits = root["rate_limit_reset_credits"] as? [String: Any],
           let n = credits["available_count"] as? Int {
            limits.append(.init(key: "resets", label: "Banked resets · \(n)",
                                percent: nil, resetsAt: nil))
        }
        return FetchedUsage(plan: root["plan_type"] as? String, limits: limits)
    }
}
