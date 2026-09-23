import Foundation

struct ModelUsageDetail: Identifiable {
    var id: String { model }
    let model: String
    let value: Double
}
struct UsageDetails {
    var title: String
    var rows: [ModelUsageDetail] = []
    var unit: String = "tokens"
    var note: String
}

/// Account-scoped server analytics. Never attributes local conversations to the current login.
enum OpenAIModelUsage {
    static func fetch(_ creds: Keychain.OpenAICreds) async throws -> UsageDetails {
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown")!
        let fmt = DateFormatter(); fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(secondsFromGMT: 0); fmt.dateFormat = "yyyy-MM-dd"
        url.queryItems = [URLQueryItem(name: "start_date", value: fmt.string(from: Date().addingTimeInterval(-6*86400))),
                         URLQueryItem(name: "end_date", value: fmt.string(from: Date())), URLQueryItem(name: "group_by", value: "day")]
        var req = URLRequest(url: url.url!); req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = creds.accountId { req.setValue(id, forHTTPHeaderField: "chatgpt-account-id") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AdapterError.transport("Model usage unavailable") }
        return try parse(data)
    }
    static func parse(_ data: Data) throws -> UsageDetails {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let unit = root["units"] as? String, ["percent", "tokens", "credits"].contains(unit),
              let days = root["data"] as? [[String: Any]] else { throw AdapterError.transport("Unknown analytics format") }
        var totals: [String: Double] = [:]
        for day in days {
            // Attribution values follow the response's units. Do not interpret the misleading
            // `models[].credits` field as money or add it to attribution (the same usage).
            for row in day["attribution"] as? [[String: Any]] ?? [] {
                guard let model = row["model"] as? String, let value = row["value"] as? Double,
                      value.isFinite, value >= 0 else { continue }
                totals[model, default: 0] += value
            }
        }
        return UsageDetails(title: "Models · last 7 UTC days", rows: totals.map { .init(model: $0.key, value: $0.value) }.sorted { $0.value > $1.value }, unit: unit,
                            note: "Reported by OpenAI for this login. Bars compare models; they are not remaining quota. Account-switch accounting is not yet independently verified.")
    }
}

enum ClaudeResetDiscovery {
    static func fetch(token: String) async -> String {
        var messages: [String] = []
        for query in ["cedar_ember=1", "at_wall=1"] {
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?\(query)&skip_spend=1")!)
            req.timeoutInterval = 15
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let summary = summarize(root) { messages.append(summary) }
            if !messages.isEmpty { break }
        }
        return messages.isEmpty ? "Reset inventory unavailable through OAuth. Check Claude’s Usage page; this does not mean zero resets." : messages.joined(separator: "\n")
    }
    static func summarize(_ root: [String: Any]) -> String? {
        var messages: [String] = []
            if let status = root["cedar_ember"] as? [String: Any] {
                let grants = status["grants"] as? [[String: Any]] ?? []
                for grant in grants {
                    guard let count = grant["resets_left"] as? Int, count > 0 else { continue }
                    let expiry = grant["ends_at"] as? String
                    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let expiry, let date = fractional.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry), date < Date() { continue }
                    let usable = status["eligible"] as? Bool == true && grant["usable_now"] as? Bool == true
                        && grant["paused"] as? Bool != true && status["next_grant_id"] as? String == grant["id"] as? String
                    messages.append("\(count) saved reset(s) · \(usable ? "available" : "conditions apply")" + (expiry.map { " · expires \($0.prefix(10))" } ?? ""))
                }
                if status["ineligible_reason"] as? String == "surface" {
                    messages.append("Reset offer requires Claude web/Desktop; OAuth cannot confirm its inventory.")
                }
            }
            if let s = root["juniper_tide"] as? [String: Any], s["eligible"] as? Bool == true,
               s["arm"] as? String == "reset", s["available"] as? Bool == true {
                messages.append("A promotional reset is available in Claude.")
            }

        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

}
