import Foundation

struct ModelUsageDetail: Identifiable {
    var id: String { identifier ?? model }
    let model: String
    let value: Double
    var identifier: String? = nil
    var caption: String? = nil
    /// The quota's reset instant, for showing a model as an ordinary limit row.
    var resetsAt: Date? = nil
}
struct GoogleQuotaGroup: Identifiable {
    let id: String
    let title: String
    let description: String
    let rows: [ModelUsageDetail]
}

struct UsageDetails {
    var title: String
    var rows: [ModelUsageDetail] = []
    var unit: String = "tokens"
    var note: String
    var emptyMessage: String = "No model usage reported."
    var summary: String? = nil
    var freshnessWarning: String? = nil
    var googleGroups: [GoogleQuotaGroup]? = nil
    var groupFailure: String? = nil
}

/// Account-scoped server analytics. Never attributes local conversations to the current login.
enum OpenAIModelUsage {
    static func fetch(_ creds: Keychain.OpenAICreds) async throws -> UsageDetails {
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown")!
        let fmt = DateFormatter(); fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(secondsFromGMT: 0); fmt.dateFormat = "yyyy-MM-dd"
        url.queryItems = [URLQueryItem(name: "start_date", value: fmt.string(from: Date().addingTimeInterval(-29*86400))),
                         URLQueryItem(name: "end_date", value: fmt.string(from: Date())), URLQueryItem(name: "group_by", value: "day")]
        var req = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData); req.timeoutInterval = 20
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = creds.accountId { req.setValue(id, forHTTPHeaderField: "chatgpt-account-id") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AdapterError.transport("Model usage: no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AdapterError.notSignedIn }
        guard http.statusCode == 200 else { throw AdapterError.transport("Model usage HTTP \(http.statusCode)") }
        return try parse(data)
    }
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageDetails {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let unit = root["units"] as? String, ["percent", "tokens", "credits"].contains(unit),
              let days = root["data"] as? [[String: Any]] else { throw AdapterError.transport("Unknown analytics format") }
        var totals: [String: Double] = [:]
        var latest: String?
        let fmt = DateFormatter(); fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(secondsFromGMT: 0); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)
        let start = fmt.string(from: now.addingTimeInterval(-29 * 86400))
        for day in days {
            guard let date = day["date"] as? String, fmt.date(from: date) != nil else {
                throw AdapterError.transport("OpenAI returned an invalid model activity date")
            }
            guard date >= start, date <= today else { continue }
            // Both arrays represent the same usage. Prefer attribution when present;
            // older responses only contain models[].credits, still in root.units.
            let attribution = day["attribution"] as? [[String: Any]] ?? []
            let rows = attribution.isEmpty ? (day["models"] as? [[String: Any]] ?? []) : attribution
            let field = attribution.isEmpty ? "credits" : "value"
            for row in rows {
                guard let model = row["model"] as? String, !model.isEmpty,
                      let value = row[field] as? Double, value.isFinite, value > 0 else { continue }
                totals[model, default: 0] += value
                latest = max(latest ?? date, date)
            }
        }
        let cutoff = fmt.string(from: now.addingTimeInterval(-2 * 86400))
        let warning = latest.map { $0 < cutoff ? "No recent model activity returned by OpenAI. These historical totals do not include usage after \($0)." : nil } ?? nil
        return UsageDetails(title: "Model history · last 30 UTC days",
                            rows: totals.map { .init(model: $0.key, value: $0.value) }.sorted { $0.value == $1.value ? $0.model < $1.model : $0.value > $1.value }, unit: unit,
                            note: (unit == "percent" ? "Daily percentages are added as percentage points (pp); these are not token counts or your current quota. " : "") + "Bars compare model totals. This history may be delayed or incomplete. Account-switch billing has not been independently verified.",
                            emptyMessage: "OpenAI reports no model activity for this period.",
                            summary: "OpenAI server · \(unit == "percent" ? "percentage points (pp)" : unit)" + (latest.map { "\nLatest activity reported: \($0)" } ?? ""),
                            freshnessWarning: warning)
    }
}

/// Current quota is separate from historical token consumption.
enum GoogleModelDetails {
    /// Only backend-declared groups establish shared quota identity. Equal
    /// percentages or model display names are not evidence of a shared pool.
    static func parseGroups(_ root: [String: Any]) throws -> [GoogleQuotaGroup] {
        let payload = (root["response"] as? [String: Any]) ?? root
        let groups = payload["groups"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let result = groups.compactMap { group -> GoogleQuotaGroup? in
            guard let name = group["displayName"] as? String else { return nil }
            let groupID = (group["groupId"] as? String) ?? name
            guard seen.insert(groupID).inserted else { return nil }
            var bucketIDs = Set<String>()
            let rows = (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> ModelUsageDetail? in
                guard bucket["disabled"] as? Bool != true,
                      let fraction = (bucket["remainingFraction"] as? Double)
                        ?? (bucket["remaining"] as? [String: Any])?["remainingFraction"] as? Double,
                      fraction.isFinite, (0...1).contains(fraction),
                      let label = bucket["displayName"] as? String else { return nil }
                let id = (bucket["bucketId"] as? String) ?? label
                guard bucketIDs.insert(id).inserted else { return nil }
                let title = label.replacingOccurrences(of: " Limit Remaining", with: "", options: .caseInsensitive)
                return ModelUsageDetail(model: title, value: (1 - fraction) * 100, identifier: groupID + "/" + id,
                                        caption: resetCaption(bucket["resetTime"]))
            }
            guard !rows.isEmpty else { return nil }
            return GoogleQuotaGroup(id: groupID, title: name, description: group["description"] as? String ?? "Shared limits reported by Google", rows: rows)
        }
        guard !result.isEmpty else { throw AdapterError.transport("Google returned no shared quota pools") }
        return result
    }

    static func resetDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: string) ?? fractional.date(from: string)
    }

    private static func resetCaption(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = ISO8601DateFormatter().date(from: string) ?? fractional.date(from: string) else { return nil }
        return "Resets " + date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The model catalog can report 100% availability without measuring usage.
    /// Take amounts from the account's explicit quota buckets; use the catalog for labels only.
    static func parseVerified(models: [String: Any], quota: [String: Any]) throws -> UsageDetails {
        let catalog = models["models"] as? [String: [String: Any]] ?? [:]
        let buckets = quota["buckets"] as? [[String: Any]] ?? []
        var rows: [ModelUsageDetail] = []
        var seen = Set<String>()
        for bucket in buckets {
            guard let id = bucket["modelId"] as? String,
                  !id.hasPrefix("chat_"), !id.hasPrefix("tab_"), !id.hasPrefix("rev"),
                  let remaining = (bucket["remainingFraction"] as? Double)
                    ?? (bucket["remaining"] as? [String: Any])?["remainingFraction"] as? Double,
                  remaining.isFinite, (0...1).contains(remaining),
                  bucket["disabled"] as? Bool != true,
                  catalog[id]?["disabled"] as? Bool != true,
                  catalog[id]?["isHidden"] as? Bool != true else { continue }
            let type = bucket["tokenType"] as? String ?? ""
            let key = "\(id)|\(type)"
            guard seen.insert(key).inserted else { continue }
            let name = (catalog[id]?["displayName"] as? String) ?? id
            rows.append(.init(model: name, value: (1 - remaining) * 100, identifier: key,
                              caption: resetCaption(bucket["resetTime"]), resetsAt: resetDate(bucket["resetTime"])))
        }
        // Same title can describe different canonical IDs. Preserve those rows,
        // but label the variants explicitly instead of showing identical bars.
        let titles = Dictionary(grouping: rows, by: \.model)
        rows = rows.map { row in
            var out = row
            if (titles[row.model]?.count ?? 0) > 1 {
                out.caption = row.id.split(separator: "|").map(String.init).joined(separator: " · ")
            }
            return out
        }
        guard !rows.isEmpty else { throw AdapterError.transport("Google returned no measurable model quota buckets") }
        return UsageDetails(title: "Antigravity · model quota used", rows: rows.sorted { $0.id < $1.id }, unit: "quotaPercent",
                            note: "Quota used, not tokens. Models can share the pools shown in Quota pools.")
    }

    static func parse(_ root: [String: Any]) throws -> UsageDetails {
        let entries: [(String, [String: Any])]
        if let dict = root["models"] as? [String: [String: Any]] {
            entries = dict.map { ($0.key, $0.value) }
        } else if let array = root["models"] as? [[String: Any]] {
            entries = array.compactMap { model in
                guard let id = (model["modelId"] as? String) ?? (model["name"] as? String) else { return nil }
                return (id, model)
            }
        } else { throw AdapterError.transport("Google returned no model quota data") }
        var byID: [String: ModelUsageDetail] = [:]
        for (id, model) in entries {
            guard !id.hasPrefix("chat_"), !id.hasPrefix("tab_"), !id.hasPrefix("rev"),
                  let quota = model["quotaInfo"] as? [String: Any],
                  let remaining = quota["remainingFraction"] as? Double,
                  remaining.isFinite, (0...1).contains(remaining) else { continue }
            let name = (model["displayName"] as? String) ?? id
            byID[id] = .init(model: name, value: (1 - remaining) * 100, identifier: id)
        }
        return UsageDetails(title: "Antigravity · model quota used", rows: byID.values.sorted { $0.model == $1.model ? $0.id < $1.id : $0.model < $1.model }, unit: "quotaPercent",
                            note: "Current limits for this Google account. Models can share a quota pool. These are quota percentages, not token totals.",
                            emptyMessage: "Google returned no individual model quotas. Shared limits remain above.")
    }
}
