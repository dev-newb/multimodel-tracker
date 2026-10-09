import Foundation

/// Account-scoped reset metadata; never contains grant IDs or authentication data.
struct BankedResetDetails: Codable, Hashable {
    let availableCount: Int
    let expirations: [Date]
    let checkedAt: Date
    var lookupFailed = false

    static let warningInterval: TimeInterval = 72 * 60 * 60

    enum ParseError: Error { case malformed }

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = root["available_count"] as? Int, count >= 0,
              let credits = root["credits"] as? [[String: Any]] else { throw ParseError.malformed }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        var seen = Set<String>()
        let dates = credits.compactMap { credit -> Date? in
            guard (credit["status"] as? String)?.lowercased() == "available" else { return nil }
            if let id = credit["id"] as? String, !seen.insert(id).inserted { return nil }
            guard let raw = credit["expires_at"] as? String else { return nil }
            return fractional.date(from: raw) ?? standard.date(from: raw)
        }.sorted()
        // A count mismatch can occur across backend updates; do not claim a
        // complete expiration schedule from an inconsistent response.
        guard dates.count <= count else { throw ParseError.malformed }
        return Self(availableCount: count, expirations: dates, checkedAt: now)
    }

    func expiresSoon(at now: Date = Date()) -> Bool {
        !lookupFailed && expirations.contains {
            let remaining = $0.timeIntervalSince(now)
            return remaining > 0 && remaining <= Self.warningInterval
        }
    }

    func tooltip(at now: Date = Date(), timeZone: TimeZone = .current) -> String {
        if availableCount == 0 { return "No banked resets available." }
        if lookupFailed { return "Expiration dates could not be retrieved from OpenAI. They will be checked again on refresh." }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        let groups = Dictionary(grouping: expirations, by: { $0 }).sorted { $0.key < $1.key }
        var lines = ["Banked reset expirations"]
        for (date, values) in groups {
            let count = values.count
            let remaining = date.timeIntervalSince(now)
            let relative: String
            if remaining <= 0 { relative = "expired; awaiting refresh" }
            else if remaining >= 86400 {
                let days = Int(ceil(remaining / 86400))
                relative = "expires in \(days) days"
            } else if remaining >= 3600 {
                let hours = Int(ceil(remaining / 3600))
                relative = "expires in \(hours) \(hours == 1 ? "hour" : "hours")"
            } else {
                let minutes = max(1, Int(ceil(remaining / 60)))
                relative = "expires in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
            }
            lines.append("\(count) \(count == 1 ? "reset" : "resets"): \(formatter.string(from: date))\n\(relative)")
        }
        let unknown = availableCount - expirations.count
        if unknown > 0 { lines.append("\(unknown) \(unknown == 1 ? "reset" : "resets"): expiration not provided by OpenAI.") }
        lines.append("Checked \(formatter.string(from: checkedAt))")
        return lines.joined(separator: "\n\n")
    }
}
