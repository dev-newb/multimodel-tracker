import SwiftUI

/// Deliberately NOT a copy of the reference: that one is a single-account,
/// single-vendor list. This has to carry up to twelve accounts, so the
/// hierarchy is provider → account → pools, with a coloured provider rail
/// doing the work its section headers can't at this density.
struct PopoverView: View {
    @ObservedObject var store: Store
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            // No fixed cap: a hard 460 started scrolling the moment Gemini
            // added rows. fixedSize lets the ScrollView take its content's
            // ideal height so the popover snaps to whatever is there, and the
            // ceiling only engages when the content genuinely outgrows the
            // screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // First run: this is where a new user lands, so each
                    // vendor's first action lives here, not behind Config.
                    if store.accounts.isEmpty { FirstRunView(store: store) }
                    ForEach(Provider.allCases) { provider in
                        let accts = store.accounts(for: provider)
                        if !accts.isEmpty { section(provider, accts) }
                    }
                }
                .padding(.vertical, 12)
            }
            // Same rubber-banding fix as the Config panel: no bounce while the
            // list fits, normal scrolling once it doesn't.
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maxListHeight)
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 340)
        // Without this the popover is see-through: NSPopover supplies no
        // material when its content is a plain SwiftUI hierarchy.
        .background(.regularMaterial)
    }

    /// For "all different at once": each account's first dead bar starts this
    /// many styles past the base, counting dead bars across the whole popover
    /// so no two show the same animation (mod the style count).
    private var maxedOffsets: [UUID: Int] {
        var n = 0
        var out: [UUID: Int] = [:]
        for p in Provider.allCases {
            for a in store.accounts(for: p) {
                out[a.id] = n
                n += a.limits.filter { ($0.percent ?? 0) >= 100 }.count
            }
        }
        return out
    }

    /// Same distribution for burning bars.
    private var burningOffsets: [UUID: Int] {
        var n = 0
        var out: [UUID: Int] = [:]
        for p in Provider.allCases {
            for a in store.accounts(for: p) {
                out[a.id] = n
                n += a.limits.filter { $0.burning && ($0.percent ?? 0) < 100 }.count
            }
        }
        return out
    }

    /// Leave room for the header, footer and the menu bar itself; below that
    /// the popover simply grows.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 160)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Multimodel Tracker").font(.system(size: 14, weight: .semibold))
            // Refresh lives up here as an icon, beside the name it refreshes.
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh now")
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if store.offline {
                // One calm note for an outage, not an NSURLError on every
                // card — the cards keep their last numbers underneath.
                Text("Offline — retrying")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            } else {
                Text(store.lastRefresh.map(Self.ago) ?? "never")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func section(_ p: Provider, _ accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(p.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(p.accent)
                Text("\(accounts.count)/\(Provider.maxAccountsPerProvider)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)

            ForEach(accounts) { account in
                AccountCard(account: account, accent: p.accent,
                            maxedStyle: store.effectiveMaxedStyle,
                            maxedOffset: store.maxedVaried ? maxedOffsets[account.id] ?? 0 : -1,
                            burnBase: store.effectiveBurnStyle,
                            burnOffset: store.burnVaried ? burningOffsets[account.id] ?? 0 : -1,
                            animating: store.uiVisible,
                            onSignIn: { Task { await store.signIn(account) } },
                            onRemove: { store.remove(account.id) })
                    .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Config…") { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) }
                .buttonStyle(.plain).font(.system(size: 12))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    static func ago(_ d: Date) -> String {
        let m = Int(-d.timeIntervalSinceNow / 60)
        return m < 1 ? "just now" : "\(m)m ago"
    }
}

/// One subscription: a coloured rail, the account label, then its pools.
struct AccountCard: View {
    let account: Account
    let accent: Color
    let maxedStyle: MaxedStyle
    /// -1 = synced (every dead bar shows maxedStyle); otherwise the ordinal
    /// of this account's first dead bar in the whole popover.
    var maxedOffset: Int = -1
    var burnBase: BurnStyle = .firestorm
    /// -1 = consistent; otherwise this account's first burning bar's ordinal.
    var burnOffset: Int = -1
    var animating = true
    /// Fix-it-where-you-see-it: an account whose sign-in lapsed gets its
    /// Sign in button on the card that shows the error.
    var onSignIn: (() -> Void)? = nil
    /// Remove the account from here, without a trip to Config.
    var onRemove: (() -> Void)? = nil
    @State private var confirmingRemove = false

    /// A small ✕ in the card's corner. One click ARMS it — it becomes a red
    /// "Remove" for three seconds — and a second click removes. Removal also
    /// deletes the account's stored credentials (deliberately, so --recover
    /// can't resurrect a deleted account), so a stray click in a popover you
    /// open all day must not be enough on its own.
    @ViewBuilder
    private func removeControl(_ onRemove: @escaping () -> Void) -> some View {
        if confirmingRemove {
            Button {
                onRemove()
            } label: {
                Text("Remove")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.14), in: Capsule())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click again to remove this account")
            .task {
                try? await Task.sleep(for: .seconds(3))
                confirmingRemove = false
            }
        } else {
            Button {
                confirmingRemove = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this account")
        }
    }

    /// Style for the Nth dead bar in this card under the variety setting.
    /// Index arithmetic, not rawValue — the raw values have a hole where
    /// flatline used to be.
    private func styleForMaxed(_ ordinal: Int) -> MaxedStyle {
        guard maxedOffset >= 0 else { return maxedStyle }
        let all = MaxedStyle.allCases
        let base = all.firstIndex(of: maxedStyle) ?? 0
        return all[(base + maxedOffset + ordinal) % all.count]
    }

    private func styleForBurn(_ ordinal: Int) -> BurnStyle {
        guard burnOffset >= 0 else { return burnBase }
        let all = BurnStyle.allCases
        let base = all.firstIndex(of: burnBase) ?? 0
        return all[(base + burnOffset + ordinal) % all.count]
    }

    /// Limit id → ordinal among this card's burning bars.
    private var burnOrdinals: [UsageLimit.ID: Int] {
        var n = 0
        var out: [UsageLimit.ID: Int] = [:]
        for l in account.limits where l.burning && (l.percent ?? 0) < 100 { out[l.id] = n; n += 1 }
        return out
    }

    /// Limit id → its ordinal among this card's dead bars.
    private var maxedOrdinals: [UsageLimit.ID: Int] {
        var n = 0
        var out: [UsageLimit.ID: Int] = [:]
        for l in account.limits where (l.percent ?? 0) >= 100 { out[l.id] = n; n += 1 }
        return out
    }

    /// Nil while the data is fresh enough to trust. The poll is 3 min, so
    /// anything past 10 gets called out rather than shown as current.
    private var staleLabel: String? {
        guard account.error == nil, !account.limits.isEmpty else { return nil }
        guard let seen = account.lastRefreshed else { return "never refreshed" }
        let mins = Int(Date().timeIntervalSince(seen) / 60)
        guard mins >= 10 else { return nil }
        return mins >= 120 ? "stale \(mins / 60)h" : "stale \(mins)m"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.85)).frame(width: 3)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    // displayName, NOT label: the whole point of nicknames is
                    // that they show here.
                    Text(account.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let sub = account.subtitle {
                        Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if let plan = account.plan {
                        Text(plan.uppercased())
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(accent.opacity(0.16), in: Capsule())
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    // A usage tracker that quietly shows old numbers is worse
                    // than one that shows nothing: a stalled refresh once left
                    // 33% on screen while the account was actually maxed out.
                    if let stale = staleLabel {
                        Text(stale)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    if let onRemove { removeControl(onRemove) }
                }
                if let err = account.error {
                    HStack(spacing: 8) {
                        Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                        if let onSignIn, account.provider != .google,
                           err.localizedCaseInsensitiveContains("sign") {
                            Button("Sign in", action: onSignIn)
                                .font(.system(size: 10)).controlSize(.small)
                        }
                    }
                } else if account.limits.isEmpty {
                    Text("No data yet").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ForEach(account.limits) { l in
                        LimitRow(limit: l, accent: accent,
                                 maxedStyle: styleForMaxed(maxedOrdinals[l.id] ?? 0),
                                 burnStyle: styleForBurn(burnOrdinals[l.id] ?? 0),
                                 animating: animating)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LimitRow: View {
    let limit: UsageLimit
    let accent: Color
    var maxedStyle: MaxedStyle = .glitch
    var burnStyle: BurnStyle = .firestorm
    var animating = true
    /// Review-only: --render-tip pins the tooltip open so its size and
    /// position can be checked without a live mouse.
    var forceHover = false
    @State private var hovering = false
    private var showTip: Bool { hovering || forceHover }
    @Environment(\.colorScheme) private var scheme

    /// .secondary/.tertiary are TRANSLUCENT — a bright trace behind them
    /// shines through the glyphs, which reads as "rendering over text" even
    /// with correct z-order. Limit rows use opaque equivalents so nothing
    /// bleeds through, here or on the row a bleed drop falls into.
    private var opaqueSecondary: Color { scheme == .dark ? Color(white: 0.66) : Color(white: 0.37) }
    private var opaqueTertiary: Color { scheme == .dark ? Color(white: 0.48) : Color(white: 0.55) }

    /// Amber past 75, red past 90 — the bar earns attention rather than
    /// wearing the provider colour the whole way up.
    private var barColor: Color {
        guard let p = limit.percent else { return .secondary.opacity(0.4) }
        if p >= 90 { return .red }
        if p >= 75 { return .orange }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(limit.label).font(.system(size: 11)).foregroundStyle(opaqueSecondary).lineLimit(1)
                Spacer()
                if let p = limit.percent {
                    Text("\(Int(p))%").font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(limit.burning ? Color(red: 1, green: 0.68, blue: 0.25) : .primary)
                }
                Text(limit.resetText).font(.system(size: 10)).foregroundStyle(opaqueTertiary)
            }
            if isMaxed {
                // Placeholder keeping the capsule's slot; the artwork is on
                // the row background so text renders over it.
                Color.clear.frame(height: MaxedBar.barH)
            } else if limit.burning, limit.percent != nil {
                Color.clear.frame(height: BurningBar.barH)
            } else if limit.percent != nil {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(barColor)
                            .frame(width: max(2, geo.size.width * limit.fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        // The whole row is the hover target, not just the reset text, and the
        // tooltip is ours: .help() waits 1-2s and often never fires inside a
        // non-activating panel. contentShape makes the gaps hoverable too.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .bottomTrailing) {
            if showTip {
                Text(limit.resetDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .fixedSize()
                    // Sits over the bar so it can never be clipped by the
                    // popover's scroll bounds, and never covers the numbers.
                    .offset(y: 9)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.09), value: hovering)
        .zIndex(showTip ? 1 : 0)
        .background(alignment: .bottom) {
            if limit.burning, !isMaxed {
                BurningBar(style: burnStyle, fraction: limit.fraction, animating: animating)
                    .offset(y: BurningBar.below)
            }
            if isMaxed {
                // Bottom edge rides `below` pt past the strip so drops can
                // fall out of the track; the trace band lands over the label,
                // underneath its text.
                MaxedBar(style: maxedStyle, animating: animating).offset(y: MaxedBar.below)
            }
        }
    }

    private var isMaxed: Bool { (limit.percent ?? 0) >= 100 }
}


/// The popover's empty state: no accounts yet. One row per vendor, each with
/// its REAL first action — an import of a login already on this Mac where
/// one exists, or the browser sign-in — because a lone "Sign in" button is
/// ambiguous in a three-vendor app. Import failures say so right here.
struct FirstRunView: View {
    @ObservedObject var store: Store
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your first account")
                .font(.system(size: 13, weight: .semibold))
            Text("Usage limits show here and in the menu bar once an account is signed in — up to \(Provider.maxAccountsPerProvider) per vendor.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Provider.allCases) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(p.accent).frame(width: 8, height: 8)
                        Text(p.displayName).font(.system(size: 12, weight: .semibold))
                    }
                    HStack(spacing: 8) {
                        switch p {
                        case .anthropic:
                            Button("Import Claude Code") {
                                report(store.importClaudeCode() == nil
                                       ? "No Claude Code login found on this Mac." : nil)
                            }
                            Button("Sign in with browser") { store.addAndSignIn(.anthropic) }
                        case .openai:
                            Button("Import Codex CLI") {
                                report(store.importCodexCLI() == nil
                                       ? "No Codex CLI login found on this Mac." : nil)
                            }
                            Button("Sign in with browser") { store.addAndSignIn(.openai) }
                        case .google:
                            Button("Import Antigravity / gemini-cli") {
                                report(store.importGoogleCLI() == nil
                                       ? "No Antigravity or gemini-cli login found on this Mac." : nil)
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
    }

    private func report(_ message: String?) { note = message }
}
