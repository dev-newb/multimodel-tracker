import Foundation

/// Shape re-verified against the live endpoint 2026-08-29:
///   rate_limit { primary_window, secondary_window } — each window carries
///     { used_percent, limit_window_seconds, reset_at }, either can be null
///   additional_rate_limits[] { limit_name, metered_feature, rate_limit }
///   rate_limit_reset_credits { available_count }   (counts only, no expiry)
///
/// Pool keys are built from the metered feature plus the window LENGTH,
/// never from the primary/secondary slot: OpenAI files the same logical
/// pool in different slots per surface — a desktop token reports the weekly
/// window as secondary where the CLI token reports it as primary — so a
/// slot-based key would split one pool's burn history the moment an account
/// switches how it authenticates.
enum OpenAIParser {
    static func parse(_ data: Data) throws -> FetchedUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.transport("malformed JSON")
        }
        var limits: [UsageLimit] = []

        /// Every non-null window of one rate_limit, longest first so the row
        /// order is stable whichever slot the vendor filed them in.
        func windows(of dict: [String: Any]?) -> [(secs: Double, pct: Double, reset: Date?)] {
            guard let rl = dict else { return [] }
            var out: [(Double, Double, Date?)] = []
            for slot in ["primary_window", "secondary_window"] {
                guard let w = rl[slot] as? [String: Any],
                      let pct = w["used_percent"] as? Double else { continue }
                let secs = (w["limit_window_seconds"] as? Double)
                    ?? (w["limit_window_seconds"] as? Int).map(Double.init) ?? 0
                let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                out.append((secs, pct, reset))
            }
            return out.sorted { $0.0 > $1.0 }
        }

        func append(windowsOf dict: [String: Any]?, feature: String, display: String) {
            var seen = Set<String>()
            for (secs, pct, reset) in windows(of: dict) {
                let span = spanTag(secs)
                // Two windows of identical length in one limit would collide;
                // keep the first (they'd be duplicates anyway).
                guard seen.insert(span.key).inserted else { continue }
                limits.append(.init(key: "\(feature)_\(span.key)",
                                    label: "\(display) · \(span.label)",
                                    percent: pct, resetsAt: reset))
            }
        }

        append(windowsOf: root["rate_limit"] as? [String: Any],
               feature: "codex", display: "Codex")
        for extra in (root["additional_rate_limits"] as? [[String: Any]] ?? []) {
            let display = (extra["limit_name"] as? String) ?? "Additional"
            let feature = ((extra["metered_feature"] as? String) ?? display).lowercased()
            append(windowsOf: extra["rate_limit"] as? [String: Any],
                   feature: feature, display: display)
        }

        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            let c = root["rate_limit_reset_credits"]
            FileHandle.standardError.write("openai reset_credits raw: \(String(describing: c))\n".data(using: .utf8)!)
        }
        // Show the banked-reset count whenever the field exists — including 0.
        // Hiding the row at zero made "resets aren't showing" indistinguishable
        // from "you have none".
        var banked: Int?
        if let credits = root["rate_limit_reset_credits"] as? [String: Any],
           let n = credits["available_count"] as? Int {
            banked = n
            limits.append(.init(key: "resets", label: "Banked resets · \(n)",
                                percent: nil, resetsAt: nil))
        }
        var out = FetchedUsage(plan: root["plan_type"] as? String, limits: limits,
                               bankedResets: banked)
        // The payload names its owner; rows that never learned their email
        // (a browser sign-in whose id_token lacked one, a recovered token)
        // pick it up from here.
        out.accountEmail = root["email"] as? String
        return out
    }

    /// A window's identity and its human name, from its length. The key must
    /// be exact ("7d" is "7d" wherever it appears); the label matches the
    /// wording the rows have always used.
    private static func spanTag(_ secs: Double) -> (key: String, label: String) {
        switch secs {
        case 0:           return ("w", "window")
        case ..<86_400:   let h = max(1, Int((secs / 3600).rounded()))
                          return ("\(h)h", "\(h)h")
        case 604_800:     return ("7d", "weekly")
        default:          let d = max(1, Int((secs / 86_400).rounded()))
                          return ("\(d)d", "\(d)d")
        }
    }
}
