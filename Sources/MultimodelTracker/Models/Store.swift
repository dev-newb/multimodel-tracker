import SwiftUI
import Combine

/// Everything the UI reads. Accounts are grouped per provider and capped at
/// Provider.maxAccountsPerProvider.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private let defaultsKey = "mmt.accounts.v1"
    private let maxedViewsKey = "mmt.maxedViews"

    /// The 100% treatment currently in rotation (flatline → fracture → bleed).
    @Published private(set) var maxedStyle: MaxedStyle = .flatline

    init() {
        load(); if accounts.isEmpty { seedDemo() }
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
    /// Baseline pairs must be one poll apart (3 min); allow slack for a
    /// missed poll but reject gaps that span sleep or downtime.
    static let burnPairMaxGap: TimeInterval = 7.5 * 60

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

    /// -1 = cycle every 3rd viewing (the default); otherwise a pinned
    /// MaxedStyle rawValue chosen in the Accounts window.
    @Published private(set) var maxedFixed: Int =
        UserDefaults.standard.object(forKey: "mmt.maxedFixed") as? Int ?? -1
    /// When several pools are dead at once: false = all show the same
    /// animation, true = each gets a different one.
    @Published private(set) var maxedVaried: Bool =
        UserDefaults.standard.bool(forKey: "mmt.maxedVaried")

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
        MaxedStyle(rawValue: ((max(n, 1) - 1) / 3) % MaxedStyle.allCases.count) ?? .flatline
    }

    func accounts(for p: Provider) -> [Account] { accounts.filter { $0.provider == p } }

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
        Keychain.deleteAll(for: id)
        accounts.removeAll { $0.id == id }
        save()
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
        guard canAdd(.openai), let creds = CodexCLIImport.read() else { return nil }
        var a = Account(provider: .openai, label: creds.email ?? "Codex CLI")
        Keychain.storeOpenAI(accessToken: creds.accessToken, accountId: creds.accountId, for: a.id)
        a.nickname = "Codex CLI"
        accounts.append(a); save()
        Task { await refresh(a) }
        return a
    }

    /// Google's "sign-in": adopt the Antigravity or gemini-cli login already
    /// on this Mac. The adapter reads those sources directly at fetch time,
    /// so the account is a named slot rather than a credential holder — which
    /// also means one is enough.
    @discardableResult
    func importGoogleCLI() -> Account? {
        guard canAdd(.google), accounts(for: .google).isEmpty else { return nil }
        let viaAntigravity = GoogleCredentialSource.antigravityKeychainBlob() != nil
        guard viaAntigravity || GoogleCredentialSource.geminiCLITokenBlob() != nil else { return nil }
        var a = Account(provider: .google, label: viaAntigravity ? "Antigravity" : "gemini-cli")
        a.nickname = viaAntigravity ? "Antigravity" : "gemini-cli"
        accounts.append(a); save()
        Task { await refresh(a) }
        return a
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account; save()
    }

    /// Refreshes every account concurrently, but staggered per provider — N
    /// accounts hitting one vendor at the same instant is exactly what gets a
    /// client rate-limited or fingerprinted.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
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
        var a = account
        // The imported Codex account can lose its keychain item when the
        // item's ACL is deliberately reset (signature migration). The source
        // of truth — ~/.codex/auth.json — is still there, and re-storing from
        // it makes THIS build the item's creator, which is exactly the clean
        // ACL binding wanted. Heal silently instead of erroring.
        if a.provider == .openai, a.nickname == "Codex CLI",
           (try? await Keychain.openAICredentialsAsync(for: a.id)) == nil,
           let creds = CodexCLIImport.read() {
            Keychain.storeOpenAI(accessToken: creds.accessToken,
                                 accountId: creds.accountId, for: a.id)
        }
        do {
            let fetched = try await ProviderRegistry.adapter(for: a.provider).fetch(account: a)
            if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
                FileHandle.standardError.write(
                    "refresh \(a.provider.rawValue)/\(a.displayName): \(fetched.limits.map(\.key).joined(separator: ","))\n"
                        .data(using: .utf8)!)
            }
            a.limits = markBurning(fetched: fetched.limits, accountID: a.id)
            a.plan = fetched.plan
            a.error = nil; a.lastRefreshed = Date()
        } catch {
            a.error = String(describing: error)
        }
        update(a)
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
            // 48h of 3-min polls is 960; the detector needs far less.
            if samples.count > 700 { samples.removeFirst(samples.count - 700) }
            samples.removeAll { now.timeIntervalSince($0.t) > 48 * 3600 }
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
        if let d = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(d, forKey: defaultsKey)
        }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let a = try? JSONDecoder().decode([Account].self, from: d) else { return }
        accounts = a
    }

    /// Until the adapters are wired, show the shape of the thing.
    private func seedDemo() {
        accounts = [
            Account(provider: .anthropic, label: "personal@…", plan: "Max", limits: [
                .init(key: "5h",     label: "5-hour limit",       percent: 11, resetsAt: Date().addingTimeInterval(720)),
                .init(key: "weekly", label: "Weekly · all models", percent: 49, resetsAt: Date().addingTimeInterval(86_400)),
                .init(key: "fable",  label: "Weekly · Fable",      percent: 66, resetsAt: Date().addingTimeInterval(86_400))
            ], lastRefreshed: Date()),
            Account(provider: .openai, label: "work@…", plan: "Pro", limits: [
                .init(key: "codex",  label: "Codex · weekly", percent: 17, resetsAt: Date().addingTimeInterval(540_000)),
                .init(key: "spark",  label: "Spark · weekly", percent: 0,  resetsAt: Date().addingTimeInterval(600_000))
            ], lastRefreshed: Date())
        ]
    }
}
