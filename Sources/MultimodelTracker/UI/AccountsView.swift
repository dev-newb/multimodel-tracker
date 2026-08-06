import SwiftUI

/// Where accounts are added, nicknamed, signed in and removed.
struct AccountsView: View {
    @ObservedObject var store: Store
    @State private var signIn: SignInWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Accounts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("up to \(Provider.maxAccountsPerProvider) per provider")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                // Replaces the traffic lights: this panel has no title bar, so
                // it needs its own way back to the tray.
                Button {
                    NotificationCenter.default.post(name: .mmtShowTray, object: nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to the tracker")
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
            Divider()
            deadBarSection
        }
        .frame(width: 480)
        // The panel is borderless and clear, so the view carries the window's
        // material and shape itself.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Double-click on empty space = "take me back to the tray". Controls
        // (buttons, nickname fields) consume their own clicks, so only the
        // background reaches this gesture.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .mmtShowTray, object: nil)
        }
    }

    /// Bar-effect preferences. Each category picks a distribution first —
    /// consistent across pools, or all different at once — and only the
    /// consistent case shows an animation picker: with "all different" the
    /// assignment is derived, so listing specific animations would be a lie.
    private var deadBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BAR EFFECTS").font(.system(size: 10, weight: .bold)).tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("When several are dead").font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(get: { store.maxedVaried },
                                              set: { store.setMaxedVaried($0) })) {
                    Text("Consistent across pools").tag(false)
                    Text("All different at once").tag(true)
                }
                .labelsHidden().fixedSize()
            }
            if !store.maxedVaried {
                HStack(spacing: 8) {
                    Text("Dead animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { store.maxedFixed },
                                                  set: { store.setMaxedFixed($0) })) {
                        Text("Cycle every 3rd view").tag(-1)
                        ForEach(MaxedStyle.allCases, id: \.rawValue) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            HStack(spacing: 8) {
                Text("When several are burning").font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(get: { store.burnVaried },
                                              set: { store.setBurnVaried($0) })) {
                    Text("Consistent across pools").tag(false)
                    Text("All different at once").tag(true)
                }
                .labelsHidden().fixedSize()
            }
            if !store.burnVaried {
                HStack(spacing: 8) {
                    Text("Burning animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { store.burnFixed },
                                                  set: { store.setBurnFixed($0) })) {
                        Text("Cycle every 3rd view").tag(-1)
                        ForEach(BurnStyle.allCases, id: \.rawValue) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .padding(16)
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
                if p == .google {
                    // The adapter reads the Antigravity/gemini-cli login that
                    // already lives on this Mac — importing IS the sign-in.
                    Button("Import Antigravity / gemini-cli") { store.importGoogleCLI() }
                        .font(.system(size: 11))
                        .disabled(!store.accounts(for: .google).isEmpty)
                } else {
                    Button("Add") { addAccount(p) }
                        .font(.system(size: 11))
                        .disabled(!store.canAdd(p))
                }
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
        case .openai:    return "Import the Codex CLI login, or add an account and sign in to chatgpt.com."
        case .google:    return "Import the Antigravity or gemini-cli login already on this Mac."
        }
    }

    private func addAccount(_ p: Provider) {
        let n = store.accounts(for: p).count + 1
        guard let account = store.add(p, label: "\(p.displayName) account \(n)") else { return }
        if p != .google { beginSignIn(account) }
    }

    private func beginSignIn(_ account: Account) {
        guard account.provider != .google else { return }
        var controller: SignInWindowController?
        let c = SignInWindowController(account: account) { ok in
            guard ok else { return }
            // OpenAI sign-in learns the email; put it on the row so the
            // account is recognisable, like the Codex import does.
            if let email = controller?.email { store.setLabel(email, for: account.id) }
            Task { await store.refresh(account) }
        }
        controller = c
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
                    // Commit on every keystroke. Committing only on focus loss
                    // lost the edit outright: this lives in a non-activating
                    // panel, so closing it (or clicking straight back to the
                    // tray) never delivers the focus change.
                    .onChange(of: draft) { onNickname($0) }
                Text(account.subtitle ?? account.label)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if account.provider != .google {
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
