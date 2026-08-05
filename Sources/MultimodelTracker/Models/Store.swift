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

    init() { load(); if accounts.isEmpty { seedDemo() } }

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
           (try? Keychain.openAICredentials(for: a.id)) == nil,
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
            a.limits = fetched.limits; a.plan = fetched.plan
            a.error = nil; a.lastRefreshed = Date()
        } catch {
            a.error = String(describing: error)
        }
        update(a)
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
