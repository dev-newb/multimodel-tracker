import SwiftUI

/// The three vendors tracked. Each carries its own accent so a glance at the
/// popover tells you whose limits you're looking at without reading labels.
enum Provider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, google
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .google:    return "Google"
        }
    }
    var accent: Color {
        switch self {
        case .anthropic: return Color(red: 0.85, green: 0.47, blue: 0.34)   // clay
        case .openai:    return Color(red: 0.06, green: 0.64, blue: 0.50)   // teal
        case .google:    return Color(red: 0.26, green: 0.52, blue: 0.96)   // blue
        }
    }
    /// Hard ceiling per vendor — four subscriptions each, per the brief.
    static let maxAccountsPerProvider = 4
}

/// One usage pool inside an account (5-hour window, weekly, a scoped model…).
struct UsageLimit: Identifiable, Codable, Hashable {
    var id: String { key }
    let key: String
    let label: String
    /// 0...100. nil means the provider reported no data for this pool.
    let percent: Double?
    let resetsAt: Date?

    var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }

    /// "resets 12m" / "resets 1d" — deliberately terse; the popover is narrow.
    var resetText: String {
        guard let r = resetsAt else { return "—" }
        let secs = r.timeIntervalSinceNow
        if secs <= 0 { return "due" }
        let m = Int(secs / 60)
        if m < 60 { return "resets \(m)m" }
        let h = m / 60
        if h < 24 { return "resets \(h)h" }
        return "resets \(h / 24)d"
    }
}

/// A single subscription. Several of these can share a Provider.
struct Account: Identifiable, Codable {
    let id: UUID
    var provider: Provider
    /// User-facing name — defaults to the email once we can read one.
    var label: String
    var plan: String?
    var limits: [UsageLimit]
    var lastRefreshed: Date?
    var error: String?

    init(id: UUID = UUID(), provider: Provider, label: String,
         plan: String? = nil, limits: [UsageLimit] = [],
         lastRefreshed: Date? = nil, error: String? = nil) {
        self.id = id; self.provider = provider; self.label = label
        self.plan = plan; self.limits = limits
        self.lastRefreshed = lastRefreshed; self.error = error
    }

    /// The number the menu bar badge shows: the worst pool in this account.
    var worstPercent: Double? {
        limits.compactMap(\.percent).max()
    }
}
