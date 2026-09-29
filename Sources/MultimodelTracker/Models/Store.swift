import SwiftUI
import Combine
import WebKit

/// Everything the UI reads. Accounts are grouped per provider and capped at
/// Provider.maxAccountsPerProvider.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var accounts: [Account] = [] {
        didSet { settleExpansion() }
    }
    @Published private(set) var dismissedSetupProviders: Set<Provider> =
        Set((UserDefaults.standard.stringArray(forKey: "mmt.dismissedSetupProviders") ?? [])
            .compactMap(Provider.init(rawValue:)))
    var providersNeedingSetup: [Provider] {
        Provider.allCases.filter {
            accounts(for: $0).isEmpty && !dismissedSetupProviders.contains($0)
        }
    }
    func dismissSetup(for provider: Provider) {
        dismissedSetupProviders.insert(provider)
        UserDefaults.standard.set(dismissedSetupProviders.map(\.rawValue),
                                  forKey: "mmt.dismissedSetupProviders")
    }
    /// True only while the popover or Accounts panel is actually on screen.
    /// The animated bars gate on this: NSPopover keeps its view hierarchy
    /// alive after dismissal, so TimelineView(.animation) happily redraws at
    /// display rate forever behind a closed popover — measured at 25% CPU
    /// with nothing visible.
    @Published private(set) var uiVisible = false
    func setUIVisible(_ v: Bool) { if uiVisible != v { uiVisible = v } }
    @Published private(set) var isRefreshing = false
    /// When data last actually ARRIVED. An outage leaves it standing — the
    /// stale chip counts from it — rather than stamping "just now" on a pass
    /// that fetched nothing.
    @Published private(set) var lastRefresh: Date?
    /// The last pass reached no provider at all for network reasons. Shown
    /// once, in the popover header, instead of a verbose NSURLError on every
    /// card — and the cards keep their last numbers.
    @Published private(set) var offline = false
    private var passSuccesses = 0
    private var passConnectivityFailures = 0
    private var signingIn: Set<UUID> = []
    @Published var accountNotice: String?
    private var importingGoogle = false
    private var importingClaude = false

    /// The per-model breakdown under each card. OFF by default: most people
    /// want the numbers, not the anatomy, and every card grows a chevron row
    /// when it is on. A persisted toggle in Config > Layout is there for
    /// anyone who wants to see how it all organises (Rich does). --mock and
    /// the render flags turn it on so a screenshot shows everything.
    @Published private(set) var showsModelDetails =
        UserDefaults.standard.object(forKey: "mmt.showsModelDetails") as? Bool ?? false

    func setShowsModelDetails(_ show: Bool) {
        showsModelDetails = show
        if !mockMode { UserDefaults.standard.set(show, forKey: "mmt.showsModelDetails") }
    }

    private let defaultsKey = "mmt.accounts.v1"
    private let maxedViewsKey = "mmt.maxedViews"

    /// The 100% treatment currently in rotation.
    @Published private(set) var maxedStyle: MaxedStyle = .glitch

    init() {
        load()
        // No demo seed. A fresh install starts EMPTY: the badge shows the
        // gauge and the popover offers each vendor's first action. The old
        // seed ("personal@…" at 66%) predated the adapters and greeted every
        // new user with plausible numbers for accounts that didn't exist.
        migrateGoogleMachineRows()
        consolidateDuplicateAccounts()
        maxedStyle = Self.style(forViewing: UserDefaults.standard.integer(forKey: maxedViewsKey))
        burnCycleStyle = BurnStyle(rawValue:
            ((max(UserDefaults.standard.integer(forKey: "mmt.burnViews"), 1) - 1) / 3)
            % BurnStyle.allCases.count) ?? .firestorm
        loadBurnHistory()
    }

    // MARK: burn detection — ported from I'm Burning!'s anomaly detector.
    // The rules, not just the spirit: the jump is measured over a 10-minute
    // sliding window (needing 4+ minutes of data), the threshold is ADAPTIVE
    // (median + 6*MAD of this pool's own historical per-minute rates) so
    // "burning" means unusual FOR THIS POOL, with a 3-point absolute floor
    // and an 8-point fallback until 50 baseline pairs exist. Burning holds
    // for 45 minutes with hysteresis: falling below half the threshold eases
    // off over 8 minutes instead of snuffing out — a pause between prompts
    // shouldn't kill the flames.
    static let burnWindow: TimeInterval = 10 * 60
    static let burnMinWindow: TimeInterval = 4 * 60
    static let burnMinJump = 3.0
    static let burnFallbackJump = 8.0
    static let burnMADK = 6.0
    static let burnBaselineMin = 50
    static let burnSettle: TimeInterval = 45 * 60
    static let burnCooling: TimeInterval = 8 * 60
    /// How often the app polls. Everything cadence-dependent derives from
    /// this rather than hardcoding a matching constant somewhere else.
    static let pollInterval: TimeInterval = 180

    /// Baseline pairs must be roughly one poll apart: allow slack for a missed
    /// poll, but reject gaps that span sleep or downtime. COMPUTED from the
    /// poll interval, matching I'm Burning!'s sampleGapLimitMs — max(3 min,
    /// interval x 2.5) — so changing the cadence can never silently invalidate
    /// the baseline the way a stale constant would.
    static let sampleGapFloor: TimeInterval = 3 * 60
    static let sampleGapMultiplier: Double = 2.5
    static var burnPairMaxGap: TimeInterval {
        max(sampleGapFloor, pollInterval * sampleGapMultiplier)
    }

    /// The detector reads a 10-minute window plus baseline pairs older than
    /// it, and switches to the adaptive threshold at 50 pairs. At a 3-minute
    /// poll that is ~51 samples, so 240 (12 hours) is already 4x what the
    /// maths needs. The old 700/48h retention served a usage graph this app
    /// does not have, and every extra sample is re-serialised into prefs on
    /// every single refresh.
    static let burnHistoryMax = 240
    static let burnHistoryAge: TimeInterval = 12 * 3600

    // MARK: alert-sound triggers (ported from I'm Burning!)
    /// Every trigger is seeded on first observation and cannot fire on it: a
    /// fresh launch legitimately "sees" every pool, bank and burning state as
    /// new, and without the guard the app would greet you with three alarms.
    private var soundSeeded = false
    private var burningBefore: Set<String> = []
    private struct PoolSnapshot { let pct: Double; let resetsAt: Date? }
    private var poolBefore: [String: PoolSnapshot] = [:]
    private var bankedBefore: [UUID: Int] = [:]
    /// Set during a refresh pass, acted on once at the end.
    private var pendingReset = false
    private var pendingBanked = false
    private var pendingLimitReached = false

    /// Two ways a reset earns the choir, either is enough:
    ///
    ///  SUBSTANTIAL -- the pool was at the wall, or near enough to feel it,
    ///  and is now clear. On schedule or not: a maxed weekly pool coming
    ///  back is the whole point of an 18-second choir. The bar is high on
    ///  purpose. A window turning over at 55% is not a limit resetting --
    ///  the limit was never in play -- and Rich reads exactly that as
    ///  "nothing reset". A limit resets when it was biting.
    ///
    ///  EARLY -- the pool had any real usage and cleared while its promise
    ///  was still meaningfully ahead. Rich wants these heard however little
    ///  was used: an early clear is a gift. It needs a promise that can be
    ///  trusted, which is most of them -- OpenAI's are to the second, and
    ///  weekly promises land on the minute (today's weekly reset arrived at
    ///  15:00Z, promised 15:00:00Z) -- but NOT Anthropic's 5-hour pool. That
    ///  one was caught at 16% with its promise >15 min out, and nothing had
    ///  been cleared: the number and the promise simply disagree there, so
    ///  it sits out the early test. Revisit when alerts.log says otherwise.
    ///
    /// A 5-hour pool rolling over on schedule matches neither and is silent.
    static let resetFrom = 90.0                    // substantial: the limit was biting...
    static let earlyFrom = 5.0                     // early: any real usage at all...
    static let resetTo = 1.0                       // ...and now this empty
    static let earlyMargin: TimeInterval = 20 * 60 // ...with the promise still this far off

    struct BurnSample: Codable { let t: Date; let v: Double }
    private var burnHistory: [String: [BurnSample]] = [:]
    /// In-memory like I'm Burning!'s — flames don't survive a relaunch,
    /// history (below) does.
    private var burnUntil: [String: Date] = [:]
    private let burnHistoryKey = "mmt.burnHistory.v1"

    @Published private(set) var burnFixed: Int =
        UserDefaults.standard.object(forKey: "mmt.burnFixed") as? Int ?? -1
    /// When several pools are burning: false = consistent across pools,
    /// true = all different at once.
    @Published private(set) var burnVaried: Bool =
        UserDefaults.standard.bool(forKey: "mmt.burnVaried")
    @Published private(set) var burnCycleStyle: BurnStyle = .firestorm
    private let burnViewsKey = "mmt.burnViews"

    func setBurnFixed(_ v: Int) {
        burnFixed = v
        UserDefaults.standard.set(v, forKey: "mmt.burnFixed")
    }

    func setBurnVaried(_ v: Bool) {
        burnVaried = v
        UserDefaults.standard.set(v, forKey: "mmt.burnVaried")
    }

    /// What a burning bar shows: the pinned style, or wherever the cycle is.
    var effectiveBurnStyle: BurnStyle {
        BurnStyle(rawValue: burnFixed) ?? burnCycleStyle
    }

    /// Every 3rd popover-open that shows a burning bar advances the cycle,
    /// exactly like the dead-bar cycle.
    func noteBurnViewing() {
        guard burnFixed < 0 else { return }
        guard accounts.contains(where: { a in a.limits.contains { $0.burning && ($0.percent ?? 0) < 100 } })
        else { return }
        let n = UserDefaults.standard.integer(forKey: burnViewsKey) + 1
        UserDefaults.standard.set(n, forKey: burnViewsKey)
        burnCycleStyle = BurnStyle(rawValue: ((max(n, 1) - 1) / 3) % BurnStyle.allCases.count) ?? .firestorm
    }

    // MARK: --mock, for UI work only
    /// A full house of FABRICATED accounts (4 per vendor) for exercising the
    /// layouts and for screenshots. Every name and address here is invented
    /// and uses the reserved example.com domain — no real account of anyone's
    /// appears in mock runs or in any image made from them.
    /// popover's layouts. Deliberately inert: with mockMode on, save() and
    /// every refresh are no-ops, so a mock run can never write over real
    /// accounts — the data-loss trap this project has been bitten by before.
    /// Meant to run from a clone with its own bundle id, so even preferences
    /// land in a separate domain.
    private(set) var mockMode = false

    func enableMockMode() {
        mockMode = true
        showsModelDetails = true        // a mock exists to show everything
        let examples = Self.mockAccounts()
        accounts = CommandLine.arguments.contains("--mock-three")
            ? Provider.allCases.compactMap { provider in examples.first { $0.provider == provider } }
            : examples
        if CommandLine.arguments.contains("--mock-five") {
            accounts = Provider.allCases.flatMap { provider in
                Array(examples.filter { $0.provider == provider }.prefix(provider == .openai ? 1 : 2))
            }
        }
        if CommandLine.arguments.contains("--mock-stale") {
            for i in accounts.indices {
                accounts[i].nickname = nil
                accounts[i].lastRefreshed = Date().addingTimeInterval(-27 * 60)
            }
        }
        lastRefresh = Date()        // the header reads "just now", not "never"
    }

    private static func mockAccounts() -> [Account] {
        func a(_ p: Provider, _ nick: String, _ email: String, _ plan: String?,
               _ pools: [(String, String, Double?)], _ via: AuthSource = .browser) -> Account {
            var out = Account(provider: p, label: email, nickname: nick, plan: plan,
                    limits: pools.map { pool in
                        // A banked-resets row is a count, with no reset clock.
                        let hasClock = pool.2 != nil
                        return .init(key: pool.0, label: pool.1, percent: pool.2,
                                     resetsAt: hasClock ? Date().addingTimeInterval(Double.random(in: 3600...432_000)) : nil)
                    },
                    lastRefreshed: Date())
            out.authentication = AuthenticationInfo(source: via, accessExpiresAt: Date().addingTimeInterval(3600), canRefresh: via == .browser || via == .antigravity)
            return out
        }
        let cl: [(String, String, Double?)] = [("5h", "5-hour limit", 0), ("7d", "Weekly · all models", 0), ("fable", "Weekly · Fable", 0)]
        func claude(_ a5: Double, _ aw: Double, _ af: Double) -> [(String, String, Double?)] {
            [(cl[0].0, cl[0].1, a5), (cl[1].0, cl[1].1, aw), (cl[2].0, cl[2].1, af)]
        }
        func codex(_ w: Double, _ sw: Double, _ s5: Double, _ banked: Int) -> [(String, String, Double?)] {
            [("codex_7d", "Codex · weekly", w), ("spark_7d", "GPT-5.3-Codex-Spark · weekly", sw),
             ("spark_5h", "GPT-5.3-Codex-Spark · 5h", s5), ("resets", "Banked resets · \(banked)", nil)]
        }
        return [
            a(.anthropic, "Personal", "personal@example.com", "Max", claude(98, 71, 98)),
            a(.anthropic, "Work", "work@example.com", "Max", claude(0, 58, 22)),
            a(.anthropic, "Side project", "side@example.com", "Max", claude(44, 31, 12), .claudeCode),
            a(.anthropic, "Research", "research@example.com", "Max", claude(12, 91, 67)),
            a(.openai, "Personal", "personal@example.com", "Pro", codex(100, 0, 0, 1)),
            a(.openai, "Work", "work@example.com", "Pro", codex(26, 10, 4, 0), .codexCLI),
            a(.openai, "Agency", "agency@example.com", "Pro", codex(63, 0, 0, 2)),
            a(.openai, "Prototyping", "proto@example.com", "Pro", codex(88, 35, 52, 0)),
            a(.google, "Personal", "personal@example.com", "Free", [("g", "Gemini · 20 models", 0)], .antigravity),
            a(.google, "Work", "work@example.com", "Pro", [("g", "Gemini · 20 models", 12)]),
            a(.google, "Studio", "studio@example.com", "Ultra", [("g", "Gemini · 20 models", 47)]),
            a(.google, "Team", "team@example.com", "Pro", [("g", "Gemini · 20 models", 79)]),
        ]
    }

    // MARK: roll-up expansion
    /// Which account cards are open. A card is open because the user opened
    /// it, or because a default was settled for it ONCE and then left alone
    /// -- never because of what the numbers say right now. This used to be
    /// @State on the popover view and re-derived from "the vendor's worst
    /// account" on every render: the fallback usage panel rebuilds that view
    /// on every open, so every choice was forgotten, and as usage moved the
    /// worst account changed and the card Rich was looking at closed on its
    /// own. The choice is the user's; it lives here and it is persisted.
    @Published private(set) var expanded: [UUID: Bool] = Store.loadExpanded()
    private static let expandedKey = "mmt.expanded"

    func setExpanded(_ id: UUID, _ open: Bool) {
        expanded[id] = open
        saveExpanded()
    }

    /// Gives a recorded state to any account in a 2+ vendor that has none
    /// yet, so the view never has to derive one. The vendor's worst opens
    /// and the rest roll up -- unless a card in that vendor is already open,
    /// in which case the newcomer rolls up and the open one is respected.
    /// Runs on every change to the list, touches only unrecorded accounts,
    /// and so can never close a card that has a state.
    private func settleExpansion() {
        var changed = false
        for p in Provider.allCases {
            let group = accounts.filter { $0.provider == p }
            guard !group.isEmpty else { continue }
            let unsettled = group.filter { expanded[$0.id] == nil }
            guard !unsettled.isEmpty else { continue }
            let anyOpen = group.contains { expanded[$0.id] == true }
            let worst = group.max { ($0.worstPercent ?? -1) < ($1.worstPercent ?? -1) }
            for a in unsettled {
                expanded[a.id] = !anyOpen && a.id == worst?.id
                changed = true
            }
        }
        if changed { saveExpanded() }
    }

    private static func loadExpanded() -> [UUID: Bool] {
        guard let d = UserDefaults.standard.data(forKey: expandedKey),
              let raw = try? JSONDecoder().decode([String: Bool].self, from: d) else { return [:] }
        var out: [UUID: Bool] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }
    private func saveExpanded() {
        let raw = Dictionary(uniqueKeysWithValues: expanded.map { ($0.key.uuidString, $0.value) })
        if let d = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(d, forKey: Self.expandedKey)
        }
    }

    // MARK: popover overflow layout
    /// How a vendor with several accounts is shown once the popover would
    /// outgrow the screen (or always / never, per overflowMode).
    @Published private(set) var overflowLayout: OverflowLayout =
        OverflowLayout(rawValue: UserDefaults.standard.integer(forKey: "mmt.overflowLayout")) ?? .grid
    @Published private(set) var overflowMode: OverflowMode =
        OverflowMode(rawValue: UserDefaults.standard.integer(forKey: "mmt.overflowMode")) ?? .automatic

    func setOverflowLayout(_ l: OverflowLayout) {
        overflowLayout = l
        UserDefaults.standard.set(l.rawValue, forKey: "mmt.overflowLayout")
    }
    func setOverflowMode(_ m: OverflowMode) {
        overflowMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mmt.overflowMode")
    }

    // MARK: alert flashes
    /// Per event: -1 = cycle each flash (the default); otherwise a pinned
    /// style index into FlashEvent.styleNames.
    @Published private(set) var flashPicks: [FlashEvent: Int] = Dictionary(
        uniqueKeysWithValues: FlashEvent.allCases.map { e in
            (e, UserDefaults.standard.object(forKey: "mmt.flash.\(e.rawValue)") as? Int ?? -1)
        })

    func setFlashPick(_ v: Int, for e: FlashEvent) {
        flashPicks[e] = v
        UserDefaults.standard.set(v, forKey: "mmt.flash.\(e.rawValue)")
    }

    /// The style THIS flash shows: the pinned pick, or the cycle position —
    /// which advances once per flash, so consecutive alerts show the next
    /// look rather than the same one forever.
    func nextFlashStyle(for e: FlashEvent) -> Int {
        if let p = flashPicks[e], p >= 0 { return p }
        let key = "mmt.flashCycle.\(e.rawValue)"
        let n = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(n + 1, forKey: key)
        return n % FlashEvent.styleCount
    }

    /// -1 = cycle every 3rd viewing (the default); otherwise a pinned
    /// MaxedStyle rawValue chosen in the Accounts window.
    @Published private(set) var maxedFixed: Int =
        UserDefaults.standard.object(forKey: "mmt.maxedFixed") as? Int ?? -1
    /// When several pools are dead at once: false = all show the same
    /// animation, true = each gets a different one.
    @Published private(set) var maxedVaried: Bool =
        UserDefaults.standard.bool(forKey: "mmt.maxedVaried")

    /// Whether the menu-bar numbers carry each vendor's colour when healthy.
    /// The warning colours at 75% and 90% are NOT optional — severity should
    /// never be switchable off — so this only chooses between vendor accents
    /// and plain white below those thresholds.
    @Published private(set) var badgeTinted: Bool =
        UserDefaults.standard.object(forKey: "mmt.badgeTinted") as? Bool ?? true

    func setBadgeTinted(_ v: Bool) {
        badgeTinted = v
        UserDefaults.standard.set(v, forKey: "mmt.badgeTinted")
        NotificationCenter.default.post(name: .mmtBadgeStyleChanged, object: nil)
    }

    /// Which Google surface to read. Antigravity is the default: it is what
    /// the IDE actually meters, and the legacy Code Assist buckets read 0%
    /// while agent usage is in flight.
    @Published private(set) var googleMode: GoogleAuthMode =
        GoogleAuthMode(rawValue: UserDefaults.standard.integer(forKey: "mmt.googleMode")) ?? .antigravity

    func setGoogleMode(_ m: GoogleAuthMode) {
        googleMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mmt.googleMode")
        refreshGoogle()
    }

    private func refreshGoogle() {
        if let g = accounts(for: .google).first { Task { await refresh(g) } }
    }

    func setMaxedFixed(_ v: Int) {
        maxedFixed = v
        UserDefaults.standard.set(v, forKey: "mmt.maxedFixed")
    }

    func setMaxedVaried(_ v: Bool) {
        maxedVaried = v
        UserDefaults.standard.set(v, forKey: "mmt.maxedVaried")
    }

    /// What a dead bar shows right now: the pinned style, or wherever the
    /// cycle currently is.
    var effectiveMaxedStyle: MaxedStyle {
        MaxedStyle(rawValue: maxedFixed) ?? maxedStyle
    }

    /// Rich: cycle to "a new one every 3rd time user sees the dead bar".
    /// Called on each popover open; only viewings where a dead bar is actually
    /// on screen count, and the style advances every third one. A pinned
    /// style doesn't advance the counter — cycling resumes where it left off.
    func noteMaxedViewing() {
        guard maxedFixed < 0 else { return }
        guard accounts.contains(where: { a in a.limits.contains { ($0.percent ?? 0) >= 100 } })
        else { return }
        let n = UserDefaults.standard.integer(forKey: maxedViewsKey) + 1
        UserDefaults.standard.set(n, forKey: maxedViewsKey)
        maxedStyle = Self.style(forViewing: n)
    }

    private static func style(forViewing n: Int) -> MaxedStyle {
        MaxedStyle.allCases[((max(n, 1) - 1) / 3) % MaxedStyle.allCases.count]
    }

    func accounts(for p: Provider) -> [Account] { accounts.filter { $0.provider == p } }

    /// Identity is provider + verified email, independent of nickname or login source.
    private func rejectDuplicate(_ provider: Provider, email: String?, excluding id: UUID? = nil) -> Bool {
        guard accounts.contains(where: { $0.id != id && $0.matches(provider: provider, email: email) }) else { return false }
        accountNotice = "This \(provider.displayName) account is already tracked"
        return true
    }

    /// Adopts the CLI's current token into an imported row whose borrowed
    /// one has expired (or, for Codex, whose keychain item has gone -- an
    /// ACL reset does that), after checking it is the same account. Codex
    /// carries its identity in the id_token, so that check costs no network;
    /// Claude Code's blob has no email, so one profile call verifies it --
    /// once per adoption, every few hours at most. Returns false when the
    /// CLI has moved to another account, with the row's error set to say so.
    private func readoptImportedLogin(_ a: inout Account) async -> Bool {
        let margin = Date().addingTimeInterval(120)
        switch a.provider {
        case .openai:
            guard a.authSource == .codexCLI || a.nickname == "Codex CLI" else { return true }
            let stored = try? await Keychain.openAICredentialsAsync(for: a.id)
            if let stored, stored.refreshToken != nil { return true }        // a browser login renews itself
            let expiring = stored.flatMap { AuthenticationInfo.jwtExpiry($0.accessToken) }.map { $0 <= margin } ?? true
            guard expiring, let cli = CodexCLIImport.read() else { return true }
            if let mine = a.normalizedEmail, let theirs = Account.normalizedEmail(cli.email), mine != theirs {
                a.error = "Codex CLI is now signed in as \(cli.email ?? "another account"); this row tracks \(a.label). Reconnect to update it."
                return false
            }
            try? Keychain.storeOpenAI(accessToken: cli.accessToken, accountId: cli.accountId, for: a.id)
        case .anthropic:
            guard a.authSource == .claudeCode || a.nickname == "Claude Code" else { return true }
            guard let stored = try? await Keychain.anthropicCredentialsAsync(for: a.id),
                  stored.refreshToken == nil else { return true }             // browser logins renew; legacy rows have no item
            guard (stored.expiresAt ?? .distantFuture) <= margin,
                  let cli = ClaudeCodeImport.freshCreds() else { return true }
            if let mine = a.normalizedEmail {
                guard let theirs = await AnthropicAdapter.profileEmail(token: cli.accessToken) else { return true }
                if Account.normalizedEmail(theirs) != mine {
                    a.error = "Claude Code is now signed in as \(theirs); this row tracks \(a.label). Reconnect to update it."
                    return false
                }
            }
            try? Keychain.storeAnthropic(accessToken: cli.accessToken, refreshToken: nil,
                                         expiresAt: cli.expiresAt, for: a.id)
        case .google:
            break
        }
        return true
    }

    /// Retire duplicate metadata without deleting credentials. A recovery operation
    /// must not resurrect these rows; retained secrets remain available for recovery.
    private func retireDuplicate(_ duplicate: Account, keeping winner: Account) {
        let backupKey = "mmt.retiredDuplicateAccounts"
        var archived = (UserDefaults.standard.data(forKey: backupKey)).flatMap {
            try? JSONDecoder().decode([Account].self, from: $0)
        } ?? []
        if !archived.contains(where: { $0.id == duplicate.id }) { archived.append(duplicate) }
        if let data = try? JSONEncoder().encode(archived) { UserDefaults.standard.set(data, forKey: backupKey) }
        if let i = accounts.firstIndex(where: { $0.id == winner.id }),
           accounts[i].nickname?.isEmpty != false, duplicate.nickname?.isEmpty == false {
            accounts[i].nickname = duplicate.nickname
        }
        accounts.removeAll { $0.id == duplicate.id }
        expanded[duplicate.id] = nil; saveExpanded(); save()
    }

    private func consolidateDuplicateAccounts() {
        // Prefer renewable, account-specific Google credentials over the machine
        // login, which can be changed outside the tracker. Otherwise keep freshest.
        let ordered = accounts.sorted { a, b in
            if a.provider != b.provider { return a.provider.rawValue < b.provider.rawValue }
            if a.provider == .google, b.provider == .google,
               Self.isMachineGoogleRow(a.id) != Self.isMachineGoogleRow(b.id) {
                return !Self.isMachineGoogleRow(a.id)
            }
            return (a.lastRefreshed ?? .distantPast) > (b.lastRefreshed ?? .distantPast)
        }
        var winners: [Account] = []
        for account in ordered {
            if let winner = winners.first(where: { $0.matches(provider: account.provider, email: account.label) }) {
                retireDuplicate(account, keeping: winner)
            } else { winners.append(account) }
        }
    }

    func canAdd(_ p: Provider) -> Bool {
        accounts(for: p).count < Provider.maxAccountsPerProvider
    }

    @discardableResult
    func add(_ provider: Provider, label: String) -> Account? {
        guard canAdd(provider) else { return nil }
        let a = Account(provider: provider, label: label)
        accounts.append(a); save(); return a
    }

    func remove(_ id: UUID) {
        unmarkMachineGoogleRow(id)
        if !mockMode { Keychain.deleteAll(for: id) }
        // Leave nothing that --recover would faithfully resurrect: the burn
        // history and the per-account cookie jar both outlive the row.
        let prefix = "\(id)/"
        burnHistory = burnHistory.filter { !$0.key.hasPrefix(prefix) }
        saveBurnHistory()
        if !mockMode { WebSessionPool.shared.removeData(for: id) }
        if webSessionRows.contains(id) { setWebSession(false, for: id) }
        accounts.removeAll { $0.id == id }
        expanded[id] = nil; saveExpanded()
        save()
    }

    /// Surfaces a sign-in failure on the account row — a browser flow can
    /// fail while the app has no window up to report it.
    func setError(_ message: String?, for id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].error = message; save()
    }

    func setLabel(_ label: String, for id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].label = label; save()
    }

    func setNickname(_ nickname: String?, for id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].nickname = (trimmed?.isEmpty == false) ? trimmed : nil
        save()
    }

    /// One-click bootstrap: if the Codex CLI is signed in, adopt its token as
    /// the first OpenAI account rather than making the user do OAuth again.
    @discardableResult
    func importCodexCLI() -> Account? {
        guard let creds = CodexCLIImport.read() else { return nil }
        guard !rejectDuplicate(.openai, email: creds.email), canAdd(.openai) else { return nil }
        var a = Account(provider: .openai, label: creds.email ?? "Codex CLI")
        do { try Keychain.storeOpenAI(accessToken: creds.accessToken, accountId: creds.accountId, for: a.id) }
        catch { a.error = String(describing: error) }
        a.nickname = "Codex CLI"
        a.authentication = AuthenticationInfo(source: .codexCLI, accessExpiresAt: AuthenticationInfo.jwtExpiry(creds.accessToken), canRefresh: false)
        accounts.append(a); save()
        if a.error == nil { Task { await refresh(a) } }
        return a
    }

    /// The browser sign-in for a row — shared by the Sign in button and the
    /// --add-anthropic debug flag. A failure lands on the row's error text
    /// (shown in Config as well as the popover), never silently.
    func signIn(_ account: Account) async {
        guard signingIn.insert(account.id).inserted else { return }
        defer { signingIn.remove(account.id) }
        setError(nil, for: account.id)
        do {
            let email: String?
            switch account.provider {
            case .openai:
                let t = try await OpenAIOAuth.signIn()
                guard let verifiedEmail = t.email else { throw AdapterError.transport("Could not verify the selected account's email. Please try again.") }
                guard !rejectDuplicate(.openai, email: verifiedEmail, excluding: account.id) else { return }
                guard accounts.contains(where: { $0.id == account.id }) else { return }
                try Keychain.storeOpenAI(accessToken: t.accessToken, accountId: t.accountID,
                                     refreshToken: t.refreshToken, for: account.id)
                email = verifiedEmail
            case .anthropic:
                // Inside the tracker, in this row's own cookie jar: the one
                // login yields the OAuth token AND the claude.ai session that
                // banked resets are only visible on. See WebSignInWindow.
                let window = WebSignInWindow(account: account.id)
                defer { window.close() }
                let t = try await AnthropicOAuth.signIn(present: window.present)
                let verifiedEmail: String?
                if let known = t.email { verifiedEmail = known }
                else { verifiedEmail = await AnthropicAdapter.profileEmail(token: t.accessToken) }
                guard let verifiedEmail else { throw AdapterError.transport("Could not verify the selected account's email. Please try again.") }
                guard !rejectDuplicate(.anthropic, email: verifiedEmail, excluding: account.id) else { return }
                guard accounts.contains(where: { $0.id == account.id }) else { return }
                try Keychain.storeAnthropic(accessToken: t.accessToken,
                                        refreshToken: t.refreshToken,
                                        expiresAt: t.expiresAt, for: account.id)
                email = verifiedEmail
                setWebSession(await window.captureSession(), for: account.id)
            case .google:
                let t = try await GoogleOAuth.signIn()
                guard !rejectDuplicate(.google, email: t.email, excluding: account.id) else { return }
                guard accounts.contains(where: { $0.id == account.id }) else { return }
                try Keychain.storeGoogle(refreshToken: t.refreshToken, for: account.id)
                // A successful browser login replaces this row's machine import.
                // Otherwise the adapter ignores its new token and reuses the expired one.
                unmarkMachineGoogleRow(account.id)
                GoogleAdapterImpl.invalidateSession(account.credentialRevision)
                email = t.email
            }
            // The flow learns the email; put it on the row so the account is
            // recognisable, like the Codex import does.
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].replaceLogin(email: email)
            let prefix = "\(account.id)/"
            poolBefore = poolBefore.filter { !$0.key.hasPrefix(prefix) }
            burnHistory = burnHistory.filter { !$0.key.hasPrefix(prefix) }
            burnUntil = burnUntil.filter { !$0.key.hasPrefix(prefix) }
            bankedBefore[account.id] = nil
            saveBurnHistory(); save()
            await refresh(accounts[i])
        } catch LoopbackError.cancelled {
            // The user closed the sign-in window. Nothing was replaced, so a
            // working row must not be painted with an error for it.
        } catch {
            setError(error.localizedDescription, for: account.id)
        }
    }

    /// "Sign in with browser" from anywhere — the popover's first-run rows or
    /// Config's Add: a new row for the provider, then its browser flow.
    @discardableResult
    func addAndSignIn(_ provider: Provider) -> Account? {
        let n = accounts(for: provider).count + 1
        guard let a = add(provider, label: "\(provider.displayName) account \(n)") else { return nil }
        Task { await signIn(a) }
        return a
    }

    /// The Anthropic sibling of importCodexCLI: adopt Claude Code's login as
    /// the first Claude account, no browser round trip. The stored creds
    /// carry NO refresh token on purpose — see ClaudeCodeImport. When the
    /// borrowed access token expires, the user reconnects. The CLI's current
    /// login is never silently substituted.
    @discardableResult
    func importClaudeCode() async -> Account? {
        guard !importingClaude else { return nil }
        importingClaude = true
        defer { importingClaude = false }
        guard let creds = ClaudeCodeImport.freshCreds(),
              let email = await AnthropicAdapter.profileEmail(token: creds.accessToken) else { return nil }
        guard !rejectDuplicate(.anthropic, email: email), canAdd(.anthropic) else { return nil }
        var a = Account(provider: .anthropic, label: email)
        do { try Keychain.storeAnthropic(accessToken: creds.accessToken, refreshToken: nil,
                                        expiresAt: creds.expiresAt, for: a.id) }
        catch { a.error = String(describing: error) }
        a.nickname = "Claude Code"
        a.authentication = AuthenticationInfo(source: .claudeCode, accessExpiresAt: creds.expiresAt, canRefresh: false)
        accounts.append(a); save()
        if a.error == nil { Task { await refresh(a) } }
        return a
    }

    /// Google's "sign-in": adopt the Antigravity or gemini-cli login already
    /// on this Mac. The adapter reads those sources directly at fetch time,
    /// so the account is a named slot rather than a credential holder — which
    /// also means one is enough.
    /// Rows that read the ONE Antigravity/gemini-cli login on this Mac.
    /// Kept as its own preference rather than on the account, so the
    /// persisted account shape never changes (that is what once wiped the
    /// list). Without this marker, a Google row mid-sign-in would fall back
    /// to the machine credentials and show ANOTHER account's numbers under
    /// its name.
    /// Anthropic OAuth rows whose cookie jar ALSO holds a claude.ai session,
    /// because they were signed in through WebSignInWindow. Only those can
    /// show banked resets: Anthropic answers grants on the web surface
    /// alone. Kept beside the account, not in it -- the persisted Account
    /// shape does not change.
    nonisolated private static let webSessionKey = "mmt.webSessionRows"
    nonisolated static func hasWebSession(_ id: UUID) -> Bool {
        (UserDefaults.standard.array(forKey: webSessionKey) as? [String] ?? []).contains(id.uuidString)
    }
    /// The same fact, observable, for Config's "See banked resets" offer.
    @Published private(set) var webSessionRows: Set<UUID> =
        Set((UserDefaults.standard.array(forKey: "mmt.webSessionRows") as? [String] ?? []).compactMap(UUID.init))
    private func setWebSession(_ on: Bool, for id: UUID) {
        var v = Set(UserDefaults.standard.array(forKey: Self.webSessionKey) as? [String] ?? [])
        if on { v.insert(id.uuidString) } else { v.remove(id.uuidString) }
        UserDefaults.standard.set(Array(v), forKey: Self.webSessionKey)
        webSessionRows = Set(v.compactMap(UUID.init))
        WebSessionPool.shared.forgetGrants(id)
    }
    /// Called by the pool when the session has expired. The UI picks it up
    /// at the next refresh, when webSessionRows is re-read.
    nonisolated static func forgetWebSession(_ id: UUID) {
        let v = (UserDefaults.standard.array(forKey: webSessionKey) as? [String] ?? []).filter { $0 != id.uuidString }
        UserDefaults.standard.set(v, forKey: webSessionKey)
    }

    private static let machineRowsKey = "mmt.googleMachineRows"
    static func isMachineGoogleRow(_ id: UUID) -> Bool {
        (UserDefaults.standard.array(forKey: machineRowsKey) as? [String] ?? []).contains(id.uuidString)
    }
    private func markMachineGoogleRow(_ id: UUID) {
        var v = UserDefaults.standard.array(forKey: Self.machineRowsKey) as? [String] ?? []
        if !v.contains(id.uuidString) { v.append(id.uuidString) }
        UserDefaults.standard.set(v, forKey: Self.machineRowsKey)
    }
    private func unmarkMachineGoogleRow(_ id: UUID) {
        let v = (UserDefaults.standard.array(forKey: Self.machineRowsKey) as? [String] ?? [])
            .filter { $0 != id.uuidString }
        UserDefaults.standard.set(v, forKey: Self.machineRowsKey)
    }

    /// Google rows created before the marker existed read the machine
    /// login by definition — they had no other way to. Run once: after
    /// this, every row is marked at creation.
    private func migrateGoogleMachineRows() {
        let done = "mmt.googleMachineRowsMigrated"
        guard !UserDefaults.standard.bool(forKey: done) else { return }
        for a in accounts where a.provider == .google {
            // A missing keychain item answers instantly and never prompts.
            if Keychain.read(service: Keychain.googleService, account: a.id.uuidString) == nil {
                markMachineGoogleRow(a.id)
            }
        }
        UserDefaults.standard.set(true, forKey: done)
    }

    @discardableResult
    func importGoogleCLI() async -> Account? {
        // Only one row can ride the machine credentials — that login is a
        // property of the Mac, not of the row. Further Google accounts come
        // in through the browser.
        guard !importingGoogle else { return nil }
        importingGoogle = true
        defer { importingGoogle = false }
        guard canAdd(.google) else { return nil }
        let viaAntigravity = await GoogleCredentialSource.antigravityKeychainBlobAsync() != nil
        guard viaAntigravity || GoogleCredentialSource.geminiCLITokenBlob() != nil else { return nil }
        var a = Account(provider: .google, label: viaAntigravity ? "Antigravity" : "gemini-cli")
        a.nickname = viaAntigravity ? "Antigravity" : "gemini-cli"
        markMachineGoogleRow(a.id)
        accounts.append(a); save()
        await refresh(a)
        return accounts.first { $0.id == a.id }
    }

    /// Rebuilds accounts from the credentials that outlive the accounts list.
    /// Keychain items (OpenAI) and per-account WebKit data stores (Anthropic)
    /// are both keyed by the account UUID, so reusing those ids restores
    /// WORKING logins rather than empty rows.
    ///
    /// The data stores are enumerated from disk, not via
    /// `WKWebsiteDataStore.allDataStoreIdentifiers` — that API segfaults
    /// inside WebKit's run loop when called during launch (verified: SIGSEGV
    /// in fetchAllDataStoreIdentifiers).
    func recoverAccounts() async -> [String] {
        var notes: [String] = []
        var known = Set(accounts.map(\.id))
        if let data = UserDefaults.standard.data(forKey: "mmt.retiredDuplicateAccounts"),
           let retired = try? JSONDecoder().decode([Account].self, from: data) {
            known.formUnion(retired.map(\.id))
        }

        let openAIIDs = Set(Keychain.openAIAccountIDs())
        for id in openAIIDs where !known.contains(id) {
            guard canAdd(.openai) else { notes.append("openai: no free slots"); break }
            accounts.append(Account(id: id, provider: .openai, label: "Recovered OpenAI"))
            known.insert(id)
            notes.append("openai \(id.uuidString.prefix(8)) — token recovered from keychain")
        }

        // Browser-OAuth Claude accounts live in the keychain like OpenAI's;
        // the cookie-jar scan below only ever finds the legacy window logins.
        for id in Keychain.anthropicAccountIDs() where !known.contains(id) {
            guard canAdd(.anthropic) else { notes.append("anthropic: no free slots"); break }
            accounts.append(Account(id: id, provider: .anthropic, label: "Recovered Claude"))
            known.insert(id)
            notes.append("anthropic \(id.uuidString.prefix(8)) — OAuth token recovered from keychain")
        }

        for id in Self.anthropicDataStoreIDs() where !known.contains(id) && !openAIIDs.contains(id) {
            guard canAdd(.anthropic) else { notes.append("anthropic: no free slots"); break }
            accounts.append(Account(id: id, provider: .anthropic, label: "Recovered Claude"))
            known.insert(id)
            notes.append("anthropic \(id.uuidString.prefix(8)) — claude.ai session recovered")
        }

        if accounts(for: .google).isEmpty, await importGoogleCLI() != nil {
            notes.append("google — re-imported from Antigravity")
        }
        save()
        return notes
    }

    /// UUID-named WebKit data stores that have actually talked to claude.ai.
    /// Every account gets a store, so the host check is what separates a real
    /// Claude login from an OpenAI or never-used one.
    private static func anthropicDataStoreIDs() -> [UUID] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/com.devnewb.multimodeltracker/WebsiteDataStore")
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.compactMap { entry -> UUID? in
            guard let id = UUID(uuidString: entry) else { return nil }
            let dir = root.appendingPathComponent(entry)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
            var checked = 0
            for case let file as URL in walker {
                checked += 1
                if checked > 4000 { break }
                guard file.pathExtension == "sqlite" || file.lastPathComponent.contains("Cookie") else { continue }
                if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                   data.range(of: Data("claude.ai".utf8)) != nil {
                    return id
                }
            }
            return nil
        }
    }

    /// Writes back ONLY the fields a refresh produces, into the CURRENT stored
    /// account. The user may rename or re-sign-in DURING the network await;
    /// replacing the whole struct with the pre-await snapshot reverted that —
    /// a rename could silently undo itself on the next poll.
    private func applyFetched(_ fetched: Account, to id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }),
              accounts[i].applyUsage(from: fetched) else { return }
        save()
    }

    /// Refreshes every account concurrently, but staggered per provider — N
    /// accounts hitting one vendor at the same instant is exactly what gets a
    /// client rate-limited or fingerprinted.
    func refreshAll() async {
        guard !mockMode else { return }      // --mock never touches the network
        guard !isRefreshing else { return }
        isRefreshing = true
        pendingReset = false; pendingBanked = false; pendingLimitReached = false
        passSuccesses = 0; passConnectivityFailures = 0
        defer {
            isRefreshing = false
            if passSuccesses > 0 { lastRefresh = Date() }
            webSessionRows = Set((UserDefaults.standard.array(forKey: Self.webSessionKey) as? [String] ?? []).compactMap(UUID.init))
            offline = passSuccesses == 0 && passConnectivityFailures > 0
            if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
                FileHandle.standardError.write(
                    "pass: ok=\(passSuccesses) network-failures=\(passConnectivityFailures) offline=\(offline)\n"
                        .data(using: .utf8)!)
            }
            fireAlertSounds()
        }
        pruneBurnHistory()
        await withTaskGroup(of: Void.self) { group in
            for (offset, account) in accounts.enumerated() {
                group.addTask { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250 * offset))
                    await self?.refresh(account)
                }
            }
        }
    }

    func refresh(_ account: Account) async {
        guard !mockMode else { return }
        guard var a = accounts.first(where: { $0.id == account.id }) else { return }
        // An imported CLI login is re-read from the CLI when its borrowed
        // token runs out -- Claude Code and Codex keep their own copies
        // current as they run -- but only while the CLI is still signed in
        // as THIS row's account. Someone who switched accounts in the CLI
        // mid-conversation gets a row that says so and waits for a
        // reconnect, never one that quietly becomes someone else.
        guard await readoptImportedLogin(&a) else {
            if let i = accounts.firstIndex(where: { $0.id == a.id }) {
                accounts[i].needsReconnect = true; accounts[i].error = a.error; save()
            }
            return
        }
        do {
            // Cached app-owned reads: no additional prompts when the adapter reads
            // the same item. Preserve expiry even when the ensuing request fails.
            switch a.provider {
            case .openai:
                if let c = try? await Keychain.openAICredentialsAsync(for: a.id) {
                    a.authentication = AuthenticationInfo(source: c.refreshToken == nil ? .codexCLI : .browser,
                        accessExpiresAt: AuthenticationInfo.jwtExpiry(c.accessToken), canRefresh: c.refreshToken != nil)
                }
            case .anthropic:
                if let c = try? await Keychain.anthropicCredentialsAsync(for: a.id) {
                    a.authentication = AuthenticationInfo(source: c.refreshToken == nil ? .claudeCode : .browser,
                        accessExpiresAt: c.expiresAt, canRefresh: c.refreshToken != nil)
                }
            case .google: break
            }
            let adapter: UsageAdapter = a.provider == .google
                ? GoogleAdapterImpl(mode: googleMode)
                : ProviderRegistry.adapter(for: a.provider)
            let fetched = try await adapter.fetch(account: a)
            guard accounts.contains(where: { $0.id == a.id && $0.credentialRevision == a.credentialRevision }) else { return }
            if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
                FileHandle.standardError.write(
                    "refresh \(a.provider.rawValue)/\(a.displayName): \(fetched.limits.map(\.key).joined(separator: ","))\n"
                        .data(using: .utf8)!)
            }
            if let email = fetched.accountEmail {
                if let existing = a.normalizedEmail, existing != Account.normalizedEmail(email) {
                    // An external CLI changed accounts. Never attribute its usage
                    // to the old card or silently relabel that card.
                    throw AdapterError.notSignedIn
                }
                if rejectDuplicate(a.provider, email: email, excluding: a.id),
                   let winner = accounts.first(where: { $0.id != a.id && $0.matches(provider: a.provider, email: email) }) {
                    retireDuplicate(a, keeping: winner)
                    return
                }
            }
            noteAlertTriggers(fetched: fetched, accountID: a.id)
            a.limits = markBurning(fetched: fetched.limits, accountID: a.id)
            a.plan = fetched.plan
            if let src = fetched.authSource { a.authSource = src }
            if let info = fetched.authentication { a.authentication = info }
            a.needsReconnect = false
            // Providers report whose account this is; a row still wearing a
            // placeholder ("OpenAI account 2", "Claude Code") takes the email.
            if let email = fetched.accountEmail { a.label = email }
            a.error = nil; a.lastRefreshed = Date()
            passSuccesses += 1
        } catch {
            if case AdapterError.notSignedIn = error { a.needsReconnect = true }
            if Self.isConnectivity(error) {
                // Not this account's fault. Keep its last numbers (the stale
                // chip dates them) and let refreshAll report the outage once.
                passConnectivityFailures += 1
            } else {
                a.error = Self.friendlyMessage(for: error)
            }
        }
        applyFetched(a, to: account.id)
    }

    /// "The network is down", as opposed to "this account is broken": the
    /// NSURLError codes for no route / no DNS / lost connection / timeout,
    /// plus what the legacy WebKit path says when its in-page fetch fails.
    static func isConnectivity(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed].contains(ns.code) {
            return true
        }
        let text = String(describing: error)
        return text.contains("Load failed") || text.contains("offline")
            || text.contains("no response")
    }

    /// What a row shows for a real failure — never a raw NSError dump.
    static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return ns.localizedDescription }
        return String(describing: error)
    }

    /// A limit reset is a pool that fell to empty between two polls, either
    /// from substantial use or well ahead of its promised time -- see
    /// resetFrom / earlyFrom for the two paths and why both exist.
    private func noteAlertTriggers(fetched: FetchedUsage, accountID: UUID) {
        let acct = accounts.first { $0.id == accountID }
        let provider = acct?.provider
        let accountLabel = acct.map { "\($0.provider.rawValue)/\($0.displayName)" } ?? accountID.uuidString
        for limit in fetched.limits {
            guard let pct = limit.percent else { continue }
            let key = "\(accountID)/\(limit.key)"
            // A limit reset is every vendor's event. The one exclusion is
            // Google, and it is about GOOGLE'S MECHANISM: the Antigravity
            // quota is a ROLLING window (measured: resetTime = request +
            // 5h 0m 07s, advancing exactly as fast as time passed) that
            // refills continuously rather than clearing. There is no
            // discrete Google reset to detect; when there is, drop this.
            if provider != .google, let prev = poolBefore[key], pct <= Self.resetTo {
                let substantial = prev.pct >= Self.resetFrom
                // Anthropic's 5-hour promise cannot carry the early test -- see earlyFrom.
                let promiseTrusted = !(provider == .anthropic
                                       && (limit.key.hasPrefix("session") || limit.key == "five_hour"))
                let earlyBy = prev.resetsAt.map { $0.timeIntervalSinceNow } ?? 0
                let early = promiseTrusted && prev.pct >= Self.earlyFrom && earlyBy > Self.earlyMargin
                if substantial || early {
                    pendingReset = true
                    let why = substantial ? "substantial" : "early by \(Int(earlyBy / 60))m"
                    AlertLog.write("reset (\(why)): \(accountLabel) / \(limit.label) "
                                   + "\(Int(prev.pct))% -> \(Int(pct))%"
                                   + (prev.resetsAt.map { ", promised for \(AlertLog.stamp($0))" } ?? ", no promise"))
                }
            }
            // Edge trigger only: the wall is hit ONCE, when a pool crosses
            // to full — a pool sitting at 100 across polls stays silent.
            if let prev = poolBefore[key], prev.pct < 100, pct >= 100 {
                pendingLimitReached = true
                AlertLog.write("limit: \(accountLabel) / \(limit.label) \(Int(prev.pct))% -> \(Int(pct))%")
            }
            poolBefore[key] = PoolSnapshot(pct: pct, resetsAt: limit.resetsAt)
        }
        if let bank = fetched.bankedResets {
            if let prev = bankedBefore[accountID], bank > prev {
                pendingBanked = true
                AlertLog.write("banked: \(accountLabel) \(prev) -> \(bank)")
            }
            bankedBefore[accountID] = bank
        }
    }

    /// Appends this poll to each pool's history, runs the detector, and marks
    /// the burning pools. At 100% the dead-bar treatment takes over, so
    /// burning is suppressed there even if the entry is still alight.
    private func markBurning(fetched: [UsageLimit], accountID: UUID) -> [UsageLimit] {
        let now = Date()
        var changed = false
        let out = fetched.map { limit in
            var l = limit
            guard let v = limit.percent else { return l }
            let stamp = "\(accountID)/\(limit.key)"
            var samples = burnHistory[stamp] ?? []
            samples.append(BurnSample(t: now, v: v))
            if samples.count > Self.burnHistoryMax {
                samples.removeFirst(samples.count - Self.burnHistoryMax)
            }
            samples.removeAll { now.timeIntervalSince($0.t) > Self.burnHistoryAge }
            burnHistory[stamp] = samples
            changed = true
            burnUntil[stamp] = Self.evaluateBurn(samples: samples, now: now,
                                                 currentUntil: burnUntil[stamp])
            l.burning = (burnUntil[stamp].map { $0 > now } ?? false) && v < 100
            return l
        }
        if changed { saveBurnHistory() }
        return out
    }

    /// Decides which alert to play once the whole refresh pass is done.
    /// Banked outranks a reset on the same pass — it is the rarer and
    /// more notable event — and only one sound plays per refresh even when
    /// several pools clear at once.
    private func fireAlertSounds() {
        let burningNow = Set(accounts.flatMap { a in
            a.limits.filter(\.burning).map { "\(a.id)/\($0.key)" }
        })
        defer {
            burningBefore = burningNow
            soundSeeded = true
            pendingReset = false; pendingBanked = false; pendingLimitReached = false
        }
        guard soundSeeded else { return }      // never fire on first load

        // Hitting a wall outranks everything: it's the event that changes
        // what the user can do right now.
        let event: FlashEvent?
        if pendingLimitReached { event = .limit }
        else if pendingBanked { event = .banked }
        else if pendingReset { event = .reset }
        // Edge trigger: something is burning now that was not burning before.
        else if burningNow.contains(where: { !burningBefore.contains($0) }) {
            event = .burn
            // Named, like every other trigger. This was the one unlogged
            // sound, and so the one that had to be inferred the night a
            // "false reset choir" turned out to be a burn.
            for key in burningNow.subtracting(burningBefore).sorted() {
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                let acct = parts.first.flatMap(UUID.init).flatMap { id in accounts.first { $0.id == id } }
                let pool = acct?.limits.first { $0.key == parts.last }
                AlertLog.write("burn: \(acct.map { "\($0.provider.rawValue)/\($0.displayName)" } ?? key)"
                               + " / \(pool?.label ?? parts.last ?? key)"
                               + (pool?.percent.map { " at \(Int($0))%" } ?? ""))
            }
        }
        else { event = nil }
        guard let event else { return }
        Sounds.shared.play(event.soundKind)
        // The badge flash rides the same trigger — it plays even with the
        // sound muted, timed to the configured file's length either way.
        NotificationCenter.default.post(name: .mmtFlashAlert, object: nil,
                                        userInfo: ["event": event.rawValue,
                                                   "style": nextFlashStyle(for: event)])
    }

    /// Drops stale samples across EVERY pool and forgets pools entirely once
    /// they are empty. markBurning only ages the pools it touches, so a pool
    /// that stops being reported — a renamed key, a removed account, a model
    /// Google no longer lists — would otherwise sit in prefs forever.
    private func pruneBurnHistory() {
        let now = Date()
        var changed = false
        for (key, samples) in burnHistory {
            let kept = samples.filter { now.timeIntervalSince($0.t) <= Self.burnHistoryAge }
            if kept.count == samples.count { continue }
            changed = true
            if kept.isEmpty { burnHistory.removeValue(forKey: key) }
            else { burnHistory[key] = kept }
        }
        if changed { saveBurnHistory() }
    }

    /// The detector itself, pure so it can be exercised with synthetic
    /// histories (--burn-sim). Returns the new "burning until" for this pool.
    static func evaluateBurn(samples: [BurnSample], now: Date, currentUntil: Date?) -> Date? {
        let live = (currentUntil ?? .distantPast) > now ? currentUntil : nil
        guard samples.count >= 5 else { return live }

        let windowSamples = samples.filter { now.timeIntervalSince($0.t) <= burnWindow }
        guard windowSamples.count >= 2,
              let first = windowSamples.first, let last = windowSamples.last else { return live }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= burnMinWindow else { return live }

        let jump = last.v - first.v
        if jump < burnMinJump {
            // Well below any trigger — a burning pool has clearly settled.
            if let until = live, jump < burnMinJump / 2 {
                return min(until, now.addingTimeInterval(burnCooling))
            }
            return live
        }

        // Baseline: per-minute rates from consecutive pairs OLDER than the
        // window. Negative deltas are window resets, oversized gaps are
        // downtime; both poison the baseline.
        var rates: [Double] = []
        for i in 1..<samples.count {
            if now.timeIntervalSince(samples[i].t) <= burnWindow { break }
            let dt = samples[i].t.timeIntervalSince(samples[i - 1].t)
            guard dt > 0, dt <= burnPairMaxGap else { continue }
            let dv = samples[i].v - samples[i - 1].v
            guard dv >= 0 else { continue }
            rates.append(dv / (dt / 60))
        }

        let jumpRate = jump / (span / 60)
        let isAnomaly: Bool
        var adaptiveThreshold: Double?
        if rates.count >= burnBaselineMin {
            let med = Self.median(rates)
            let mad = Self.median(rates.map { abs($0 - med) }) * 1.4826
            let threshold = med + burnMADK * max(mad, 0.01)
            adaptiveThreshold = threshold
            isAnomaly = jumpRate > threshold
        } else {
            isAnomaly = jump >= burnFallbackJump
        }

        if isAnomaly { return now.addingTimeInterval(burnSettle) }
        if let until = live {
            let settled = adaptiveThreshold.map { jumpRate <= $0 / 2 }
                ?? (jump < burnFallbackJump / 2)
            // Ease off rather than snap out: dipping below the hysteresis
            // line mid-session is normal (a pause to read, a slower prompt).
            if settled { return min(until, now.addingTimeInterval(burnCooling)) }
        }
        return live
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private func saveBurnHistory() {
        if let d = try? JSONEncoder().encode(burnHistory) {
            UserDefaults.standard.set(d, forKey: burnHistoryKey)
        }
    }

    private func loadBurnHistory() {
        guard let d = UserDefaults.standard.data(forKey: burnHistoryKey),
              let h = try? JSONDecoder().decode([String: [BurnSample]].self, from: d) else { return }
        burnHistory = h
    }

    // MARK: persistence (metadata only — never tokens; those live in Keychain)
    private func save() {
        guard !mockMode else { return }      // never write over real accounts
        if let d = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(d, forKey: defaultsKey)
        }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            accounts = try JSONDecoder().decode([Account].self, from: d)
            settleExpansion()   // explicit: observers may not fire inside init
        } catch {
            // Never let a decode failure become data loss: keep a copy of the
            // bytes so a schema mistake can be recovered from, and refuse to
            // save over the original until something decodes.
            UserDefaults.standard.set(d, forKey: defaultsKey + ".unreadable")
            FileHandle.standardError.write(
                "accounts failed to decode (\(error)) — original preserved under \(defaultsKey).unreadable\n"
                    .data(using: .utf8)!)
        }
    }

}
