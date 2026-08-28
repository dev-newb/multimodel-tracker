import SwiftUI

/// Where accounts are added, nicknamed, signed in and removed.
struct AccountsView: View {
    @ObservedObject var store: Store
    @ObservedObject private var sounds = Sounds.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Back sits where a close button would on macOS — top left —
                // with the title on the right and the capacity note reading
                // into it: "up to 4 per provider  Accounts".
                Button {
                    NotificationCenter.default.post(name: .mmtShowTray, object: nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Back to the tracker")
                Spacer()
                Text("up to \(Provider.maxAccountsPerProvider) per provider")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Config").font(.system(size: 15, weight: .semibold))
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
            // No rubber-banding while everything fits: macOS lets a ScrollView
            // bounce even when content == bounds, so a two-finger drag made
            // this section wobble. basedOnSize kills that, and real scrolling
            // (and its bounce) returns only once the content overflows 680.
            .scrollBounceBehavior(.basedOnSize)
            // fixedSize makes the ScrollView adopt its content's ideal height
            // instead of stretching, so the window shrinks to what is actually
            // there; maxHeight keeps a full twelve accounts from running off
            // the screen, at which point it scrolls as before.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 680)
            Divider()
            badgeSection
            Divider()
            deadBarSection
            Divider()
            soundSection
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
        // Adding or removing an account rebuilds the rows underneath the
        // pointer. Any nickname field it was over loses its tracking area
        // mid-hover, leaving the I-beam stuck — reset on every change to the
        // list, not just on close.
        .onChange(of: store.accounts.count) { _, _ in
            NSCursor.arrow.set()
            // Belt and braces: drop any rect a destroyed row left behind.
            NSApp.windows.forEach { $0.discardCursorRects() }
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    /// Menu-bar appearance. Only the healthy colour is offered: amber at 75%
    /// and red at 90% stay on permanently.
    private var badgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MENU BAR").font(.system(size: 10, weight: .bold)).tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Numbers when healthy").font(.system(size: 12))
                    Text("Amber past 75% and red past 90% either way")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                OptionPicker(width: Self.pickerWidth,
                             options: Self.badgeOptions,
                             selection: Binding(get: { store.badgeTinted },
                                                set: { store.setBadgeTinted($0) }))
            }
        }
        .padding(16)
    }

    static let badgeOptions: [(Bool, String)] = [
        (true, "Vendor colours"), (false, "Plain white"),
    ]

    /// The three alert sounds. Each is independently switchable, can point at
    /// the user's own file, and has its own volume — matching I'm Burning!.
    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOUNDS").font(.system(size: 10, weight: .bold)).tracking(0.8)
                .foregroundStyle(.secondary)
            ForEach(SoundKind.allCases) { kind in
                SoundRow(kind: kind, sounds: sounds)
            }
        }
        .padding(16)
    }

    static let distributionOptions: [(Bool, String)] = [
        (false, "Consistent across pools"), (true, "All different at once"),
    ]
    static let deadOptions: [(Int, String)] =
        [(-1, "Cycle every 3rd view")] + MaxedStyle.allCases.map { ($0.rawValue, $0.displayName) }
    static let burnOptions: [(Int, String)] =
        [(-1, "Cycle every 3rd view")] + BurnStyle.allCases.map { ($0.rawValue, $0.displayName) }

    /// One width for every drop-down so their edges line up. They are Menus
    /// rather than Pickers because an NSPopUpButton sizes itself to the widest
    /// item in ITS OWN menu, which no .frame overrides — the distribution
    /// pickers came out wider purely because "Consistent across pools" is
    /// longer than any style name.
    ///
    /// MEASURED, not hardcoded. A fixed number would be fine across screen
    /// resolutions — points already scale with the display — but it would clip
    /// if the system font grew or the strings were ever translated. This asks
    /// the font how wide the longest label actually is, so the equal widths
    /// survive both.
    static let pickerWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12)
        let titles = distributionOptions.map(\.1) + deadOptions.map(\.1) + burnOptions.map(\.1)
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 150
        // Room for the padding and chevron, clamped so a pathological string
        // can't push the controls off a 480pt panel.
        return min(max(widest.rounded(.up) + 40, 150), 250)
    }()

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
                OptionPicker(width: Self.pickerWidth, options: Self.distributionOptions,
                             selection: Binding(get: { store.maxedVaried },
                                                set: { store.setMaxedVaried($0) }))
            }
            if !store.maxedVaried {
                HStack(spacing: 8) {
                    Text("Dead animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    OptionPicker(width: Self.pickerWidth, options: Self.deadOptions,
                                 selection: Binding(get: { store.maxedFixed },
                                                    set: { store.setMaxedFixed($0) }))
                }
                EffectPreviewRow(width: Self.pickerWidth) {
                    DeadPreview(fixed: MaxedStyle(rawValue: store.maxedFixed))
                }
            }
            HStack(spacing: 8) {
                Text("When several are burning").font(.system(size: 12))
                Spacer()
                OptionPicker(width: Self.pickerWidth, options: Self.distributionOptions,
                             selection: Binding(get: { store.burnVaried },
                                                set: { store.setBurnVaried($0) }))
            }
            if !store.burnVaried {
                HStack(spacing: 8) {
                    Text("Burning animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    OptionPicker(width: Self.pickerWidth, options: Self.burnOptions,
                                 selection: Binding(get: { store.burnFixed },
                                                    set: { store.setBurnFixed($0) }))
                }
                EffectPreviewRow(width: Self.pickerWidth) {
                    BurnPreview(fixed: BurnStyle(rawValue: store.burnFixed))
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
            if p == .google, !accounts.isEmpty {
                HStack(spacing: 8) {
                    Text("Read usage from").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { store.googleMode.rawValue },
                                                  set: { store.setGoogleMode(GoogleAuthMode(rawValue: $0) ?? .antigravity) })) {
                        ForEach(GoogleAuthMode.allCases, id: \.rawValue) { m in
                            Text(m.displayName).tag(m.rawValue)
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).frame(width: Self.pickerWidth)
                }
                .padding(.horizontal, 2)
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
        case .anthropic: return "Add an account, then sign in with your browser."
        case .openai:    return "Import the Codex CLI login, or add an account and sign in with your browser."
        case .google:    return "Import the Antigravity or gemini-cli login already on this Mac."
        }
    }

    private func addAccount(_ p: Provider) {
        let n = store.accounts(for: p).count + 1
        guard let account = store.add(p, label: "\(p.displayName) account \(n)") else { return }
        if p != .google { beginSignIn(account) }
    }

    /// Both vendors sign in through the real browser: passkeys cannot work in
    /// an embedded WKWebView (passkey-only accounts exist for both), and an
    /// existing browser session turns the flow into a single Authorize click.
    /// Google has no sign-in at all — its "login" is importing the Antigravity
    /// or gemini-cli credentials already on this Mac.
    private func beginSignIn(_ account: Account) {
        guard account.provider != .google else { return }
        Task {
            do {
                let email: String?
                switch account.provider {
                case .openai:
                    let t = try await OpenAIOAuth.signIn()
                    Keychain.storeOpenAI(accessToken: t.accessToken, accountId: t.accountID,
                                         refreshToken: t.refreshToken, for: account.id)
                    email = t.email
                case .anthropic:
                    let t = try await AnthropicOAuth.signIn()
                    Keychain.storeAnthropic(accessToken: t.accessToken,
                                            refreshToken: t.refreshToken,
                                            expiresAt: t.expiresAt, for: account.id)
                    email = t.email
                case .google:
                    return
                }
                // The flow learns the email; put it on the row so the account
                // is recognisable, like the Codex import does.
                if let email { store.setLabel(email, for: account.id) }
                await store.refresh(account)
            } catch {
                store.setError(error.localizedDescription, for: account.id)
            }
        }
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
                // Looked like a static label, so nobody knew it was editable.
                // A field chrome plus a placeholder that says what it does.
                TextField("Rename\u{2026}", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(focused ? 0.10 : 0.05),
                                in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(focused ? 0.35 : 0.12), lineWidth: 0.5))
                    .focused($focused)
                    .onSubmit { onNickname(draft) }
                    // Commit on every keystroke. Committing only on focus loss
                    // lost the edit outright: this lives in a non-activating
                    // panel, so closing it (or clicking straight back to the
                    // tray) never delivers the focus change. Skip the no-op
                    // write the initial onAppear populate would otherwise fire.
                    .onChange(of: draft) { _, new in
                        if new != (account.nickname ?? "") { onNickname(new) }
                    }
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


/// Right-aligns a preview under its picker, in the same column width.
struct EffectPreviewRow<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            content.frame(width: width)
        }
    }
}

/// Live preview of the dead-bar effect. With a style pinned it shows that
/// one; on "Cycle every 3rd view" it walks the whole set, giving each style
/// three complete loops before moving on, forever — the same rotation the
/// popover will show, just without waiting three viewings to see it.
struct DeadPreview: View {
    let fixed: MaxedStyle?
    @State private var start = Date()

    var body: some View {
        // A slow outer tick only decides WHICH style is showing; MaxedBar
        // runs its own animation clock, so this doesn't drive the drawing.
        TimelineView(.periodic(from: start, by: 0.2)) { context in
            let style = fixed ?? Self.cycled(context.date.timeIntervalSince(start))
            VStack(alignment: .leading, spacing: 2) {
                MaxedBar(style: style)
                if fixed == nil {
                    Text(style.displayName)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func cycled(_ elapsed: Double) -> MaxedStyle {
        let all = MaxedStyle.allCases
        let spans = all.map { $0.cycleSeconds * 3 }
        let total = spans.reduce(0, +)
        var t = elapsed.truncatingRemainder(dividingBy: total)
        for (i, span) in spans.enumerated() {
            if t < span { return all[i] }
            t -= span
        }
        return all[0]
    }
}

/// Same, for the burning effects. The bar sits at 62% so the leading-edge
/// treatments have somewhere to burn.
struct BurnPreview: View {
    let fixed: BurnStyle?
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.2)) { context in
            let style = fixed ?? Self.cycled(context.date.timeIntervalSince(start))
            VStack(alignment: .leading, spacing: 2) {
                BurningBar(style: style, fraction: 0.62)
                if fixed == nil {
                    Text(style.displayName)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func cycled(_ elapsed: Double) -> BurnStyle {
        let all = BurnStyle.allCases
        let spans = all.map { $0.cycleSeconds * 3 }
        let total = spans.reduce(0, +)
        var t = elapsed.truncatingRemainder(dividingBy: total)
        for (i, span) in spans.enumerated() {
            if t < span { return all[i] }
            t -= span
        }
        return all[0]
    }
}


/// A drop-down of a fixed width. See AccountsView.pickerWidth for why this
/// exists instead of Picker.
struct OptionPicker<Value: Hashable>: View {
    let width: CGFloat
    let options: [(Value, String)]
    @Binding var selection: Value

    private var title: String {
        options.first { $0.0 == selection }?.1 ?? options.first?.1 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { selection = options[i].0 }
            }
        } label: {
            Text(title).font(.system(size: 12)).lineLimit(1)
        }
        // .button keeps the native push-button chrome and puts the indicator
        // where macOS puts it; .borderlessButton drew its own leading chevron
        // and threw the background away.
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .frame(width: width)
    }
}


/// One alert sound: on/off, which file, how loud, and a way to hear it.
/// One alert sound. Laid out on a fixed grid so the controls line up down
/// the column: the previous version let each row size itself, and the buttons
/// landed at three different x positions because the filenames differ in
/// length.
struct SoundRow: View {
    let kind: SoundKind
    @ObservedObject var sounds: Sounds

    /// Shared columns: the filename gets a fixed slot so every Choose button
    /// starts at the same x, and the volume group is right-aligned.
    private static let nameColumn: CGFloat = 168
    private static let volumeColumn: CGFloat = 104

    var body: some View {
        let setting = sounds.settings[kind] ?? SoundSetting()
        let custom = sounds.isCustom(kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { setting.enabled },
                                     set: { sounds.setEnabled($0, for: kind) })) {
                    Text(kind.displayName).font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                // Test ignores the enabled flag, so a muted sound can still be
                // auditioned before switching it on.
                Button("Test") { sounds.play(kind, force: true) }
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text(sounds.label(for: kind))
                    .font(.system(size: 10.5))
                    .foregroundStyle(custom ? .secondary : .tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: Self.nameColumn, alignment: .leading)
                    .help(custom ? "Custom sound" : "Bundled default")

                Button("Choose…") { chooseFile() }.controlSize(.small)
                // Revert sits immediately beside Choose and only exists while
                // a custom file is set, so the pair reads as one control.
                if custom {
                    Button {
                        sounds.setPath(nil, for: kind)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .help("Back to \(kind.defaultLabel)")
                }

                Spacer(minLength: 8)

                Image(systemName: setting.volume < 0.01 ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                VolumeSlider(value: setting.volume, width: Self.volumeColumn) {
                    sounds.setVolume($0, for: kind)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        // An opaque card rather than bare material: the controls were sitting
        // straight on the panel's blur, which is what made them look
        // half-transparent.
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Sound"
        if panel.runModal() == .OK, let url = panel.url {
            sounds.setPath(url.path, for: kind)
        }
    }
}


/// A hand-drawn volume slider.
///
/// AppKit's Slider renders its knob through the window's vibrancy, and this
/// panel is deliberately non-opaque (borderless, clear background, material
/// supplied by the view). The knob came out transparent — the track filled
/// but the handle was invisible. Shrinking the control size only clipped the
/// track as well. Drawing it directly sidesteps the compositing entirely and
/// matches the bars this app already renders by hand.
struct VolumeSlider: View {
    let value: Double
    var width: CGFloat = 104
    let onChange: (Double) -> Void

    private let knob: CGFloat = 11
    private let track: CGFloat = 3.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let travel = max(1, w - knob)          // the knob's centre stays inside
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: track)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knob / 2 + travel * clamped, height: track)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: travel * clamped)
            }
            .frame(height: knob, alignment: .center)
            // The whole strip is draggable, and a plain click jumps the knob
            // there — minimumDistance 0 makes press and drag one gesture.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onChange(min(max((g.location.x - knob / 2) / travel, 0), 1))
                    }
            )
        }
        .frame(width: width, height: knob)
    }
}
