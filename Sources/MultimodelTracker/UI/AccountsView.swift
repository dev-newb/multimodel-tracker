import SwiftUI

/// Where accounts are added, nicknamed, signed in and removed.
struct AccountsView: View {
    @ObservedObject var store: Store
    @State private var signIn: SignInWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Accounts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("up to \(Provider.maxAccountsPerProvider) per provider")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Provider.allCases) { provider in
                        providerBlock(provider)
                    }
                }
                .padding(16)
            }
            // fixedSize makes the ScrollView adopt its content's ideal height
            // instead of stretching, so the window shrinks to what is actually
            // there; maxHeight keeps a full twelve accounts from running off
            // the screen, at which point it scrolls as before.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 680)
        }
        .frame(width: 480)
        // Double-click on empty space = "take me back to the tray". Controls
        // (buttons, nickname fields) consume their own clicks, so only the
        // background reaches this gesture.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .mmtShowTray, object: nil)
        }
    }

    private func providerBlock(_ p: Provider) -> some View {
        let accounts = store.accounts(for: p)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(p.accent).frame(width: 8, height: 8)
                Text(p.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(accounts.count)/\(Provider.maxAccountsPerProvider)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if p == .openai && store.canAdd(.openai) {
                    Button("Import Codex CLI") { store.importCodexCLI() }
                        .font(.system(size: 11))
                }
                Button("Add") { addAccount(p) }
                    .font(.system(size: 11))
                    .disabled(!store.canAdd(p))
            }
            if accounts.isEmpty {
                Text(emptyHint(p)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(accounts) { account in
                AccountRow(account: account, accent: p.accent,
                           onNickname: { store.setNickname($0, for: account.id) },
                           onSignIn:  { beginSignIn(account) },
                           onRemove:  { store.remove(account.id) })
            }
        }
    }

    private func emptyHint(_ p: Provider) -> String {
        switch p {
        case .anthropic: return "Add an account, then sign in to claude.ai in its own window."
        case .openai:    return "Import the Codex CLI login, or add an account and paste a token."
        case .google:    return "Not yet available — see README."
        }
    }

    private func addAccount(_ p: Provider) {
        let n = store.accounts(for: p).count + 1
        guard let account = store.add(p, label: "\(p.displayName) account \(n)") else { return }
        if p == .anthropic { beginSignIn(account) }
    }

    private func beginSignIn(_ account: Account) {
        guard account.provider == .anthropic else { return }
        let c = SignInWindowController(account: account) { ok in
            if ok { Task { await store.refresh(account) } }
        }
        signIn = c
        c.present()
    }
}

struct AccountRow: View {
    let account: Account
    let accent: Color
    let onNickname: (String?) -> Void
    let onSignIn: () -> Void
    let onRemove: () -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(accent.opacity(0.8)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nickname", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($focused)
                    .onSubmit { onNickname(draft) }
                    .onChange(of: focused) { isFocused in if !isFocused { onNickname(draft) } }
                Text(account.subtitle ?? account.label)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if account.provider == .anthropic {
                Button("Sign in", action: onSignIn).font(.system(size: 11))
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash").font(.system(size: 11))
            }.buttonStyle(.borderless)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .onAppear { draft = account.nickname ?? "" }
    }
}
