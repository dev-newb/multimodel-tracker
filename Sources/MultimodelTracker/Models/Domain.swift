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
    /// AppKit twin of `accent`, for the status-item badge.
    var nsAccent: NSColor {
        switch self {
        case .anthropic: return NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .openai:    return NSColor(red: 0.06, green: 0.64, blue: 0.50, alpha: 1)
        case .google:    return NSColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)
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
    var unavailableReason: String? = nil
    var bankedResetDetails: BankedResetDetails? = nil
    /// Set by the Store when this pool is burning. Derived state, NOT from
    /// the provider — and deliberately excluded from CodingKeys below.
    var burning: Bool = false

    /// `burning` is omitted on purpose. Swift's synthesised decoder does NOT
    /// fall back to a property's default value when the key is missing — it
    /// throws keyNotFound. Adding `burning` to the persisted shape therefore
    /// made every previously-saved account undecodable, which wiped Rich's
    /// real accounts and replaced them with the demo seed. Derived state must
    /// stay out of the persisted shape.
    private enum CodingKeys: String, CodingKey {
        case key, label, percent, resetsAt, unavailableReason, bankedResetDetails
    }

    var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }

    /// Hover detail behind the terse label: the actual clock time plus the
    /// full distance. Includes the weekday once it's not today.
    var resetDetail: String {
        if let unavailableReason { return unavailableReason }
        guard let r = resetsAt else { return "no reset reported" }
        let secs = r.timeIntervalSinceNow
        if secs <= 0 { return "reset due now" }
        let fmt = DateFormatter()
        let sameDay = Calendar.current.isDate(r, inSameDayAs: Date())
        fmt.dateFormat = sameDay ? "h:mm a" : "EEE h:mm a"
        let mTotal = Int(secs / 60)
        let d = mTotal / 1440, h = (mTotal % 1440) / 60, m = mTotal % 60
        var dist: [String] = []
        if d > 0 { dist.append("\(d)d") }
        if h > 0 { dist.append("\(h)h") }
        if m > 0 || dist.isEmpty { dist.append("\(m)m") }
        return "resets \(fmt.string(from: r)) · \(dist.joined(separator: " ")) from now"
    }

    /// "resets 12m" / "resets 1d" — deliberately terse; the popover is narrow.
    var resetText: String {
        if unavailableReason != nil { return "Unavailable" }
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

/// How an account's credentials were obtained. This is a different KIND of
/// fact from the plan tier, and must never occupy the tier's place on the
/// card: "Antigravity" is the route in, not something you subscribe to.
enum AuthSource: String, Codable {
    case browser, codexCLI, claudeCode, antigravity, geminiCLI, legacyCookies, unknown

    /// What the card says, or nil when there is nothing worth saying — a
    /// browser sign-in is the ordinary case and needs no badge.
    var chipLabel: String? {
        switch self {
        case .codexCLI:     return "via Codex CLI"
        case .claudeCode:   return "via Claude CLI"
        case .antigravity:  return "via Antigravity"
        case .geminiCLI:    return "via Gemini CLI"
        case .browser: return "via Browser"
        case .legacyCookies: return "via Web session"
        case .unknown: return nil
        }
    }
}

/// Non-secret metadata only. Optional on Account so older saved accounts still decode.
struct AuthenticationInfo: Codable {
    var source: AuthSource
    var accessExpiresAt: Date? = nil
    var canRefresh: Bool? = nil

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double, exp.isFinite else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// A single subscription. Several of these can share a Provider.
struct Account: Identifiable, Codable {
    let id: UUID
    var provider: Provider
    /// What the provider tells us — usually the account email.
    var label: String
    /// User-chosen name. Four subscriptions on one vendor all look alike by
    /// email, so this is how you tell "main" from "the one for work".
    var nickname: String?
    var plan: String?
    var limits: [UsageLimit]
    var lastRefreshed: Date?
    var error: String?
    var authentication: AuthenticationInfo?
    var needsReconnect: Bool?
    var authSource: AuthSource {
        get { authentication?.source ?? .unknown }
        set {
            if authentication == nil { authentication = AuthenticationInfo(source: newValue) }
            else { authentication?.source = newValue }
        }
    }
    var normalizedEmail: String? {
        Self.normalizedEmail(label)
    }
    static func normalizedEmail(_ email: String?) -> String? {
        guard let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.contains("@") else { return nil }
        return value
    }
    func matches(provider: Provider, email: String?) -> Bool {
        self.provider == provider && normalizedEmail != nil && normalizedEmail == Self.normalizedEmail(email)
    }
    var needsSignIn: Bool {
        needsReconnect == true || (authentication == nil && lastRefreshed == nil && normalizedEmail == nil)
    }
    var authenticationTooltip: String {
        var lines = [label]
        if let expiry = authentication?.accessExpiresAt {
            lines.append("Access token expires: " + expiry.formatted(date: .abbreviated, time: .standard))
        } else {
            lines.append("Access token expiry: not provided by this source.")
        }
        if needsReconnect == true {
            lines.append("Reconnect to resume provider usage updates.")
        } else if authentication?.canRefresh == true {
            lines.append("Automatic renewal is available. Sign-in expiry is not provided; access-token expiry does not end the login.")
        } else if authentication?.canRefresh == false {
            lines.append("This imported token cannot renew here. Reconnect when it expires.")
        } else {
            lines.append("Sign-in expiry is not provided by this source.")
        }
        return lines.joined(separator: "\n")
    }
    /// An in-memory identity for this login, distinct from the reusable card slot.
    /// Responses started before a replacement login must not overwrite it.
    var credentialRevision = UUID()

    mutating func replaceLogin(email: String?) {
        credentialRevision = UUID()
        label = email ?? "\(provider.displayName) account"
        plan = nil; limits = []; lastRefreshed = nil; error = nil
        authentication = AuthenticationInfo(source: .browser); needsReconnect = false
    }

    @discardableResult
    mutating func applyUsage(from fetched: Account) -> Bool {
        guard id == fetched.id, credentialRevision == fetched.credentialRevision else { return false }
        limits = fetched.limits; plan = fetched.plan; authentication = fetched.authentication
        needsReconnect = fetched.needsReconnect
        if fetched.label.contains("@") { label = fetched.label }
        error = fetched.error; lastRefreshed = fetched.lastRefreshed
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, label, nickname, plan, limits, lastRefreshed, error, authentication, needsReconnect
    }

    init(id: UUID = UUID(), provider: Provider, label: String,
         nickname: String? = nil, plan: String? = nil, limits: [UsageLimit] = [],
         lastRefreshed: Date? = nil, error: String? = nil) {
        self.id = id; self.provider = provider; self.label = label
        self.nickname = nickname; self.plan = plan; self.limits = limits
        self.lastRefreshed = lastRefreshed; self.error = error
    }

    /// Nickname wins when set; the email is the fallback.
    var displayName: String {
        if let n = nickname, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return label
    }
    /// Shown small beside the nickname so the underlying account is still visible.
    var subtitle: String? {
        (nickname?.isEmpty == false) ? label : nil
    }

    /// The number the menu bar badge shows: the worst pool in this account.
    var worstPercent: Double? {
        limits.compactMap(\.percent).max()
    }
}
