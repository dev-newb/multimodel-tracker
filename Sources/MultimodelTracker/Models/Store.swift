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
    }

    /// A pool counts as burning when it gains this many points between polls.
    /// The poll is 3 minutes, so this is roughly "on pace to exhaust the pool
    /// within the hour" — fast enough to be worth shouting about, high enough
    /// that ordinary drift stays quiet.
    static let burnThreshold: Double = 2.0
    /// Burning decays rather than latching: without another jump it clears
    /// after this long, so the bar doesn't stay on fire all day.
    static let burnHoldSeconds: TimeInterval = 12 * 60
    private var burnSeen: [String: Date] = [:]

    @Published private(set) var burnFixed: Int =
        UserDefaults.standard.object(forKey: "mmt.burnFixed") as? Int ?? -1

    func setBurnFixed(_ v: Int) {
        burnFixed = v
        UserDefaults.standard.set(v, forKey: "mmt.burnFixed")
    }

    /// Pinned style, or one chosen per pool so several burning bars differ.
    func burnStyle(forKey key: String) -> BurnStyle {
        if let pinned = BurnStyle(rawValue: burnFixed) { return pinned }
        let all = BurnStyle.allCases
        return all[abs(key.hashValue) % all.count]
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
            a.limits = Self.markBurning(previous: a.limits, fetched: fetched.limits,
                                        seen: &burnSeen, accountID: a.id)
            a.plan = fetched.plan
            a.error = nil; a.lastRefreshed = Date()
        } catch {
            a.error = String(describing: error)
        }
        update(a)
    }

    /// Compares this poll against the last one per pool. A pool that jumped
    /// is marked burning and remembered, so it keeps burning across the polls
    /// that follow until it goes quiet for burnHoldSeconds.
    private static func markBurning(previous: [UsageLimit], fetched: [UsageLimit],
                                    seen: inout [String: Date], accountID: UUID) -> [UsageLimit] {
        let now = Date()
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0.percent ?? 0) })
        return fetched.map { limit in
            var l = limit
            let stamp = "\(accountID)/\(limit.key)"
            if let old = before[limit.key], let new = limit.percent,
               new - old >= burnThreshold, new < 100 {
                seen[stamp] = now
            }
            if let last = seen[stamp] {
                if now.timeIntervalSince(last) <= burnHoldSeconds, (limit.percent ?? 0) < 100 {
                    l.burning = true
                } else {
                    seen[stamp] = nil
                }
            }
            return l
        }
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
