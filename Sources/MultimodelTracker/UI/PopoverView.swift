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
                    ForEach(Provider.allCases) { provider in
                        let accts = store.accounts(for: provider)
                        if !accts.isEmpty { section(provider, accts) }
                    }
                }
                .padding(.vertical, 12)
            }
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
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
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
                            animating: store.uiVisible)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Refresh") { Task { await store.refreshAll() } }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            Button("Accounts…") { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) }
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
                }
                if let err = account.error {
                    Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
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
                    .help(limit.resetDetail)
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
