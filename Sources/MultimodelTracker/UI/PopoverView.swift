import SwiftUI

/// Deliberately NOT a copy of the reference: that one is a single-account,
/// single-vendor list. This has to carry up to twelve accounts, so the
/// hierarchy is provider → account → pools, with a coloured provider rail
/// doing the work its section headers can't at this density.
/// The alternative presentations for a vendor with several accounts, used
/// once the popover would outgrow the screen (chosen in Config → Layout).
enum OverflowLayout: Int, CaseIterable, Identifiable {
    case grid = 0, pager = 1, tabs = 2
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .grid:  return "Two-up grid"
        case .pager: return "Vendor pager"
        case .tabs:  return "Account tabs"
        }
    }
    var blurb: String {
        switch self {
        case .grid:  return "The popover widens and a vendor's accounts sit two abreast — everything visible, half the height."
        case .pager: return "One account per vendor at a time; arrows and dots in the vendor header flip between them."
        case .tabs:  return "A tab per account under each vendor header, each showing its worst pool; click to switch."
        }
    }
    /// The popover's width under this layout.
    var popoverWidth: CGFloat { self == .grid ? 520 : 340 }
}

enum OverflowMode: Int, CaseIterable, Identifiable {
    case automatic = 0, always = 1, never = 2
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Only when it won't fit"
        case .always:    return "Always"
        case .never:     return "Never (scroll instead)"
        }
    }
}

/// Measured card heights (--measure-card), the constants the overflow
/// estimate is built from: a card is base + pools × row; an error card and
/// a rolled-up row are fixed. If the card design changes, re-measure.
enum PopoverMetrics {
    /// Measured with --measure-card, in two sizes: the model-details chevron
    /// row adds 23pt to every card that carries one. Anthropic cards never do.
    static func cardBase(details: Bool) -> CGFloat { details ? 56 : 33 }
    static func errorCard(details: Bool) -> CGFloat { details ? 83 : 60 }
    static let poolRow: CGFloat = 29
    /// The page dots under a cycling card's rows, with their spacing.
    static let cycleDots: CGFloat = 11
    static let sectionHeader: CGFloat = 20
    static let cardGap: CGFloat = 8
    static let sectionGap: CGFloat = 14
    static let listPadding: CGFloat = 24
    /// Header + divider + footer + the menu bar itself, kept clear of the
    /// list — the same allowance maxListHeight uses.
    static let chrome: CGFloat = 160

    static func cardHeight(_ a: Account, details: Bool, rows: Int? = nil) -> CGFloat {
        let has = details && a.provider != .anthropic
        if a.error != nil { return errorCard(details: has) }
        return cardBase(details: has) + poolRow * CGFloat(max(rows ?? a.limits.count, 1))
    }

    /// Rows a card will actually SHOW: a Google card padded with its plan's
    /// missing pools (PopoverView.displayed) shows its richer sibling's count.
    @MainActor
    static func shownRows(_ a: Account, among accounts: [Account]) -> Int {
        guard a.provider == .google, a.error == nil else { return a.limits.count }
        let peers = accounts.filter { $0.id != a.id && $0.error == nil && !$0.limits.isEmpty && $0.plan != a.plan }
        return max(a.limits.count, peers.map { $0.limits.filter { $0.percent != nil }.count }.max() ?? 0)
    }

    /// The list's height with EVERY card expanded — the honest worst case,
    /// and a pure function of the accounts, so the decision can't flip-flop
    /// as the user opens and closes rows.
    @MainActor
    static func fullyExpandedHeight(_ store: Store) -> CGFloat {
        var total = listPadding
        var sections = 0
        let details = store.showsModelDetails
        let cycle = store.cycleSeconds > 0
        for p in Provider.allCases {
            let accts = store.accounts(for: p)
            guard !accts.isEmpty else { continue }
            sections += 1
            total += sectionHeader
            total += accts.map { a -> CGFloat in
                // A cycling card is four rows and its dots, whatever it holds,
                // and a cycling Google card has no model panel.
                let shown = shownRows(a, among: accts)
                let cycles = cycle && a.error == nil && shown + (store.modelQuotas[a.id]?.count ?? 0) > 4
                return cardHeight(a, details: details && !(cycle && a.provider == .google),
                                  rows: cycles ? 4 : shown) + (cycles ? cycleDots : 0)
            }.reduce(0, +)
            total += cardGap * CGFloat(max(accts.count - 1, 0))
        }
        total += sectionGap * CGFloat(max(sections - 1, 0))
        return total
    }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Roll-up rows: for a vendor with 2+ accounts, each account is a
    /// one-line summary that expands in place to the full card. Which are
    /// open is the STORE's state (persisted, settled once, never derived
    /// here) -- see Store.expanded for why it cannot live in this view.

    /// The parts the window's height is measured from; see body.
    @State private var topHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    private var wantedHeight: CGFloat { (topHeight + listHeight + bottomHeight).rounded(.up) }
    private func heightReader(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { g in
            Color.clear.onAppear { report(g.size.height) }
                .onChange(of: g.size.height) { _, h in report(h) }
        }
    }

    /// Pager / tabs selection per vendor, for the app's lifetime.
    @State private var pageIndex: [Provider: Int] = [:]
    var onContentSizeChange: ((CGSize) -> Void)? = nil

    /// Whether the chosen overflow layout is in force right now. Automatic
    /// mode asks one question of the accounts and THIS screen: would the
    /// popover fit with every card expanded? Counting accounts would be the
    /// wrong unit — a Google account is one pool, an Anthropic one is three.
    private var overflowActive: Bool {
        switch store.overflowMode {
        case .always: return true
        case .never:  return false
        case .automatic:
            return PopoverMetrics.fullyExpandedHeight(store) > maxListHeight
        }
    }

    private var popoverWidth: CGFloat {
        overflowActive ? store.overflowLayout.popoverWidth : 340
    }

    private func isExpanded(_ account: Account, in accounts: [Account]) -> Bool {
        return store.expanded[account.id] ?? true      // unsettled: show, never hide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) { header; Divider().opacity(0.35) }
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReader { topHeight = $0 })
            ScrollViewReader { proxy in
                BoundedTrackerScroll(maxHeight: maxListHeight, onIdealHeight: { listHeight = $0 }) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Keep each empty vendor's actions in reach until the
                        // user explicitly dismisses that vendor's setup row.
                        if !store.providersNeedingSetup.isEmpty { FirstRunView(store: store) }
                        ForEach(Provider.allCases) { provider in
                            let accts = store.accounts(for: provider)
                            if accts.count >= 2 && overflowActive {
                                overflowSection(provider, accts)
                            } else if !accts.isEmpty {
                                section(provider, accts)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .environment(\.revealTrackerDetail) { id in proxy.scrollTo(id) }
            }
            VStack(spacing: 0) { Divider().opacity(0.35); footer }
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReader { bottomHeight = $0 })
        }
        .frame(width: popoverWidth)
        // The window is sized from what the content WANTS -- header, the
        // list's capped ideal, footer -- measured in parts, never by forcing
        // the whole view to its ideal size. Forcing it (fixedSize) meant a
        // window that came out shorter than asked -- AppKit re-applying a
        // stale popover size -- got content taller than itself, and a view
        // taller than its window is CENTRED: the header clipped off the top,
        // the footer off the bottom. Now the header and footer hold their
        // places and the list gives up the difference and scrolls.
        .onChange(of: wantedHeight) { _, h in onContentSizeChange?(CGSize(width: popoverWidth, height: h)) }
        .onChange(of: popoverWidth) { _, w in onContentSizeChange?(CGSize(width: w, height: wantedHeight)) }
        .frame(maxHeight: .infinity, alignment: .top)
        // Without this the popover is see-through: NSPopover supplies no
        // material when its content is a plain SwiftUI hierarchy.
        .background(.regularMaterial)
        .accountNotice(store)
    }

    // MARK: overflow layouts — A grid, B pager, D tabs

    /// B: on GOOGLE, a pool a sibling account reports and this one doesn't is
    /// shown as "not on <plan>" -- Google's Free plan has no 5-hour windows
    /// (verified: it sends two buckets where Pro sends four), and saying so
    /// is information, not padding. Only when the plans differ, and only
    /// between accounts whose last read succeeded, so an error or a blip can
    /// never pass for a plan difference. Google only: on OpenAI the Spark
    /// pools come and go on the SAME plan, where "not on Pro" would be false.
    private func displayed(_ a: Account, among accounts: [Account]) -> Account {
        guard a.provider == .google, a.error == nil, !a.limits.isEmpty else { return a }
        let peers = accounts.filter { $0.id != a.id && $0.error == nil && !$0.limits.isEmpty && $0.plan != a.plan }
        guard let reference = peers.max(by: { $0.limits.count < $1.limits.count }),
              reference.limits.count > a.limits.count else { return a }
        let mine = Dictionary(a.limits.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [UsageLimit] = []
        for l in reference.limits where l.percent != nil {
            if let own = mine[l.label] { rows.append(own); continue }
            var gap = UsageLimit(key: "absent-\(l.key)", label: l.label, percent: nil, resetsAt: nil)
            gap.unavailable = a.plan.map { "not on \($0)" } ?? "not on this plan"
            rows.append(gap)
        }
        let placed = Set(rows.map(\.label))
        rows += a.limits.filter { !placed.contains($0.label) }
        var shown = a
        shown.limits = rows
        return shown
    }

    private func card(_ account: Account, _ p: Provider, compact: Bool = false) -> some View {
        AccountCard(account: account, accent: p.accent,
                    maxedStyle: store.effectiveMaxedStyle,
                    maxedOffset: store.maxedVaried ? maxedOffsets[account.id] ?? 0 : -1,
                    burnBase: store.effectiveBurnStyle,
                    burnOffset: store.burnVaried ? burningOffsets[account.id] ?? 0 : -1,
                    animating: store.uiVisible,
                    onSignIn: { Task { await store.signIn(account) } },
                    onRemove: { store.remove(account.id) },
                    onRetryKeychain: {
                        Keychain.invalidateCache(for: account.id)
                        Task { await store.refresh(account) }
                    },
                    collapsible: true, expanded: store.expanded[account.id] ?? true,
                    onToggle: { toggleAccount(account) }, compact: compact, showsModelDetails: store.showsModelDetails,
                    extraRows: store.modelQuotas[account.id] ?? [], cycleSeconds: store.cycleSeconds)
    }

    private func toggleAccount(_ account: Account) {
        TrackerPopoverLayout.beginAnimation(duration: reduceMotion ? 0 : 0.16)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            store.setExpanded(account.id, !(store.expanded[account.id] ?? true))
        }
    }

    @ViewBuilder
    private func overflowSection(_ p: Provider, _ accounts: [Account]) -> some View {
        let idx = min(pageIndex[p] ?? 0, accounts.count - 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(p.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(p.accent)
                Text("\(accounts.count)/\(Provider.maxAccountsPerProvider)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if store.overflowLayout == .pager {
                    // ‹ dots › — a dot goes red when the page it stands for
                    // is in trouble, so a hidden problem still shows.
                    HStack(spacing: 5) {
                        PagerArrow(direction: .left, label: "Previous \(p.displayName) account") {
                            pageIndex[p] = (idx - 1 + accounts.count) % accounts.count
                        }
                        ForEach(accounts.indices, id: \.self) { i in
                            Circle()
                                .fill(i == idx ? Color.primary
                                      : ((accounts[i].worstPercent ?? 0) >= 90 ? Color.red : Color.primary.opacity(0.25)))
                                .frame(width: 6.5, height: 6.5)
                        }
                        PagerArrow(direction: .right, label: "Next \(p.displayName) account") {
                            pageIndex[p] = (idx + 1) % accounts.count
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            switch store.overflowLayout {
            case .grid:
                // Each card keeps its OWN height, top-aligned in its row. A grid
                // row offers every cell the tallest cell's height, and the card's
                // accent bar -- a shape with no height of its own -- took all of
                // it: a rolled-up card beside an open one became a tall empty box
                // instead of rolling up.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top),
                                    GridItem(.flexible(), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    // A: OPEN cards share their row's height, so bottoms line up
                    // whatever the cause (plans, one card's details open, an
                    // error); a ROLLED card keeps its own one-line height.
                    ForEach(accounts) { a in
                        card(displayed(a, among: accounts), p, compact: true)
                            .fixedSize(horizontal: false, vertical: !(store.expanded[a.id] ?? true))
                    }
                }
                .padding(.horizontal, 12)
            case .pager:
                card(displayed(accounts[idx], among: accounts), p)
                    .id(accounts[idx].id)
                    .padding(.horizontal, 12)
            case .tabs:
                HStack(spacing: 3) {
                    ForEach(accounts.indices, id: \.self) { i in
                        let a = accounts[i]
                        let hot = (a.worstPercent ?? 0) >= 90
                        Button { pageIndex[p] = i } label: {
                            HStack(spacing: 4) {
                                Text(a.displayName).lineLimit(1)
                                if let w = a.worstPercent {
                                    Text("\(Int(w))%").fontWeight(.bold)
                                        .foregroundStyle(hot ? Color.red : (i == idx ? Color.primary : Color.secondary))
                                }
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(i == idx ? Color.primary : Color.secondary)
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(i == idx ? 0.12 : 0.05),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                card(displayed(accounts[idx], among: accounts), p)
                    .id(accounts[idx].id)
                    .padding(.horizontal, 12)
            }
        }
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
    /// The screen the popover is anchored on, handed in by the delegate from
    /// the status item's own window. NSScreen.main is the KEY window's screen
    /// — a menu-bar app often has none, and it goes stale (the same trap that
    /// once sent windows to the wrong Space) — so on two monitors the ceiling
    /// could be sized for the other display.
    var anchorScreen: NSScreen? = nil

    private var maxListHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = anchorScreen
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        return max(240, visible - 160)
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
                let open = isExpanded(account, in: accounts)
                AccountCard(account: displayed(account, among: accounts), accent: p.accent,
                            maxedStyle: store.effectiveMaxedStyle,
                            maxedOffset: store.maxedVaried ? maxedOffsets[account.id] ?? 0 : -1,
                            burnBase: store.effectiveBurnStyle,
                            burnOffset: store.burnVaried ? burningOffsets[account.id] ?? 0 : -1,
                            animating: store.uiVisible && open,
                            onSignIn: { Task { await store.signIn(account) } },
                            onRemove: { store.remove(account.id) },
                    onRetryKeychain: {
                        Keychain.invalidateCache(for: account.id)
                        Task { await store.refresh(account) }
                    },
                            collapsible: true,
                            expanded: open,
                            onToggle: {
                                TrackerPopoverLayout.beginAnimation(duration: reduceMotion ? 0 : 0.16)
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                    store.setExpanded(account.id, !open)
                                }
                            }, showsModelDetails: store.showsModelDetails,
                            extraRows: store.modelQuotas[account.id] ?? [], cycleSeconds: store.cycleSeconds)
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
    var onRetryKeychain: (() -> Void)? = nil
    @State private var confirmingRemove = false
    @State private var hoveringRemove = false
    /// Roll-up rows (vendors with 2+ accounts): the header row IS the
    /// summary. Collapsed, it carries the worst pool's % and a mini bar and
    /// hides the pools; expanded, it is exactly the card as it always was.
    /// One element that changes shape — never a summary stacked on a card.
    var collapsible = false
    var expanded = true
    var onToggle: (() -> Void)? = nil
    /// Grid cells are half-width: the email steps aside and the plan chip
    /// shrinks so the name and the numbers keep their room.
    var compact = false
    @State private var hoveringRow = false
    var detailPreview: UsageDetails? = nil
    var showsModelDetails = true
    /// Rows beyond the card's own pools -- a Google account's model quotas --
    /// shown only while cycling.
    var extraRows: [UsageLimit] = []
    /// Seconds per page when cycling; 0 is off (see Store.cycleSeconds).
    var cycleSeconds = 0
    @State private var page = 0
    @State private var nudge = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Google's daily service reports different balances from production's.
    /// When that is where these numbers come from -- because Antigravity is
    /// there -- the card says so.
    private var onDailyService: Bool {
        account.provider == .google && AntigravityServiceRoute.current() == .daily
    }
    private var dailyTag: some View {
        outlinedChip("daily")
            .help("Reading Google's daily service, as Antigravity is. Config > Google > Service pins it.")
    }
    private func outlinedChip(_ text: String) -> some View {
        Text(text).font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
    }

    private var worstColor: Color {
        guard let p = account.worstPercent else { return .secondary }
        if p >= 90 { return .red }
        if p >= 75 { return .orange }
        return accent
    }

    /// A small ✕ in the card's corner. One click ARMS it — it becomes a red
    /// "Remove" for three seconds — and a second click removes. Removal also
    /// deletes the account's stored credentials (deliberately, so --recover
    /// can't resurrect a deleted account), so a stray click in a popover you
    /// open all day must not be enough on its own.
    @ViewBuilder
    private func removeControl(_ onRemove: @escaping () -> Void) -> some View {
        // Both states share one trailing-anchored ZStack so the hand-off is a
        // crossfade in place: the ✕ squashes on press and dissolves while the
        // pill grows out of the same corner. Render-layer animation only —
        // opacity and scale — which is the kind that stays smooth here.
        ZStack(alignment: .trailing) {
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
                .buttonStyle(PressSquashStyle())
                .help("Click again to remove this account")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)))
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(Self.armCurve) { confirmingRemove = false }
                }
            } else {
                Button {
                    withAnimation(Self.armCurve) { confirmingRemove = true }
                } label: {
                    // Rests quiet; under the pointer it brightens and gains a
                    // faint disc, so it reads as live without shouting.
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(hoveringRemove ? 0.85 : 0.35))
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(hoveringRemove ? 0.10 : 0), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressSquashStyle())
                .onHover { hoveringRemove = $0 }
                .animation(.easeOut(duration: 0.12), value: hoveringRemove)
                .help("Remove this account")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(height: 18)
    }

    private static let armCurve: Animation = .spring(response: 0.28, dampingFraction: 0.78)

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
                    // Collapsed, the name gets the room: email and plan chip
                    // are detail, and they return the moment the row opens.
                    let rolled = collapsible && !expanded
                    Text(account.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .help(account.authenticationTooltip)
                        .layoutPriority(rolled || compact ? 1 : 0)
                    if let sub = account.subtitle, !rolled, !compact {
                        Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            .help(account.authenticationTooltip)
                    }
                    Spacer()
                    // The chips sit AFTER the spacer, so they line up down
                    // the column instead of starting wherever each account's
                    // name and email happen to end.
                    if let via = account.authSource.chipLabel, !rolled, !compact {
                        // How the credentials were found — a different kind
                        // of fact, so deliberately a different kind of chip:
                        // outlined and grey, never mistakable for a tier.
                        // Only an unusual route says anything at all.
                        Text(via)
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if onDailyService, !rolled, !compact { dailyTag }
                    if let plan = account.plan, !rolled {
                        // The subscription TIER — filled, in the vendor's
                        // accent. Nothing else belongs in this slot.
                        Text(plan.uppercased())
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            // One width for every tier, so PRO and FREE start
                            // at the same x down the column instead of each
                            // hugging its own text.
                            .frame(minWidth: 46)
                            .background(accent.opacity(0.16), in: Capsule())
                            .foregroundStyle(accent)
                    }
                    // A usage tracker that quietly shows old numbers is worse
                    // than one that shows nothing: a stalled refresh once left
                    // 33% on screen while the account was actually maxed out.
                    if let stale = staleLabel {
                        Text(stale)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    if collapsible && !expanded {
                        // The badge's own logic, per row: the worst pool.
                        // fixedSize, or the name's layoutPriority starves this
                        // of width and "16%" wraps one character per line --
                        // which is what happened the moment a fourth account
                        // arrived with no nickname and an email for a name.
                        if let w = account.worstPercent {
                            Text("\(Int(w))%")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(worstColor)
                            Capsule().fill(Color.primary.opacity(0.10))
                                .frame(width: 44, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(worstColor)
                                        .frame(width: max(2, 44 * min(max(w / 100, 0), 1)))
                                }
                        } else if account.error != nil {
                            Text("!").font(.system(size: 11, weight: .bold)).fixedSize().foregroundStyle(.orange)
                        }
                    }
                    if collapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                            .help(expanded ? "Roll up account" : "Expand account")
                    }
                    if let onRemove { removeControl(onRemove) }
                }
                // The header row is the click target for roll-up: an explicit
                // tap gesture there, not on the whole card, so the pools' own
                // hover tooltips and the ✕ keep working normally.
                .contentShape(Rectangle())
                .onTapGesture { if collapsible { onToggle?() } }
                .onHover { hoveringRow = $0 }
                if !collapsible || expanded {
                // Compact cards move the route chips below the name; the daily
                // tag rides along, since the grid is where a details-on user
                // lives and the tag is no use hidden there.
                if compact, account.authSource.chipLabel != nil || onDailyService {
                    HStack(spacing: 4) {
                        if let via = account.authSource.chipLabel { outlinedChip(via) }
                        if onDailyService { dailyTag }
                    }
                }
                if let err = account.error {
                    HStack(spacing: 8) {
                        Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                        if let onRetryKeychain, err.localizedCaseInsensitiveContains("keychain") {
                            Button("Retry Keychain", action: onRetryKeychain).font(.system(size: 10)).controlSize(.small)
                        }
                        if let onSignIn,
                           err.localizedCaseInsensitiveContains("sign"), !err.localizedCaseInsensitiveContains("keychain") {
                            Button(account.needsReconnect == true ? "Reconnect" : "Sign in", action: onSignIn)
                                .font(.system(size: 10)).controlSize(.small)
                        }
                    }
                } else if account.limits.isEmpty {
                    Text("No data yet").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if cycling {
                    cyclingRows
                } else {
                    ForEach(account.limits) { l in limitRow(l) }
                }
                // With cycling on, a Google card's models come round in the
                // card itself, so its separate model panel would repeat them.
                if showsModelDetails, account.provider != .anthropic,
                   !(account.provider == .google && cycleSeconds > 0) {
                    ModelUsageDisclosure(account: account, accent: accent, preview: detailPreview,
                                         initiallyExpanded: detailPreview != nil)
                        .id(account.credentialRevision)
                }
                }   // expanded
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, collapsible && !expanded ? 7 : 9).padding(.horizontal, 10)
        .background(Color.primary.opacity(collapsible && !expanded && hoveringRow ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 8))
        // A click on the card that no control claims turns the page now.
        // The header row, the chevrons and the cross keep their own clicks.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { turnPage() }
        .clipped()
    }

    // MARK: cycling
    private static let perPage = 4
    private var allRows: [UsageLimit] { account.limits + extraRows }
    private var cycling: Bool {
        cycleSeconds > 0 && account.error == nil && allRows.count > Self.perPage && (!collapsible || expanded)
    }
    private var pages: [[UsageLimit]] {
        let rows = allRows
        return stride(from: 0, to: rows.count, by: Self.perPage).map { Array(rows[$0..<min($0 + Self.perPage, rows.count)]) }
    }
    private func limitRow(_ l: UsageLimit) -> some View {
        LimitRow(limit: l, accent: accent,
                 maxedStyle: styleForMaxed(maxedOrdinals[l.id] ?? 0),
                 burnStyle: styleForBurn(burnOrdinals[l.id] ?? 0),
                 animating: animating)
    }
    /// An invisible stand-in with a real row's geometry, so a short last
    /// page is exactly as tall as a full one.
    private static let filler = UsageLimit(key: "filler", label: " ", percent: 0, resetsAt: nil)

    /// Four rows at a time, cross-fading to the next four every
    /// cycleSeconds while the card is on screen. Dots say where you are.
    @ViewBuilder private var cyclingRows: some View {
        let all = pages
        let current = page % all.count
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(all[current]) { l in limitRow(l) }
                    ForEach(0..<(Self.perPage - all[current].count), id: \.self) { _ in
                        limitRow(Self.filler).hidden()
                    }
                }
                .id(current)
                .transition(.opacity)
            }
            HStack(spacing: 4) {
                ForEach(all.indices, id: \.self) { i in
                    Circle().fill(Color.primary.opacity(i == current ? 0.55 : 0.18)).frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Page \(current + 1) of \(all.count)")
        }
        .task(id: "\(cycleSeconds)-\(all.count)-\(nudge)-\(animating)") {
            guard animating, all.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(cycleSeconds)))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { page = (page + 1) % all.count }
            }
        }
    }

    /// Turns the page now, and restarts the timer so the new page gets its
    /// full turn instead of whatever was left of the old one's.
    private func turnPage() {
        guard cycling else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { page = (page + 1) % max(pages.count, 1) }
        nudge += 1
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
                Text(limit.unavailable ?? limit.resetText).font(.system(size: 10)).foregroundStyle(opaqueTertiary)
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
            } else if limit.unavailable != nil {
                // Same slot as a real bar, so a row that says "not on this
                // plan" is exactly as tall as one with a value.
                Capsule().fill(Color.primary.opacity(0.05)).frame(height: 5)
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


/// Setup rows for vendors without accounts. One row per vendor, each with
/// its REAL first action — an import of a login already on this Mac where
/// one exists, or the browser sign-in — because a lone "Sign in" button is
/// ambiguous in a three-vendor app. Import failures say so right here.
struct FirstRunView: View {
    @ObservedObject var store: Store
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.accounts.isEmpty ? "Add your first account" : "Add another provider")
                .font(.system(size: 13, weight: .semibold))
            if store.accounts.isEmpty {
                Text("Usage limits show here and in the menu bar once an account is signed in — up to \(Provider.maxAccountsPerProvider) per vendor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(store.providersNeedingSetup) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(p.accent).frame(width: 8, height: 8)
                        Text(p.displayName).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button { store.dismissSetup(for: p) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss \(p.displayName) setup")
                    }
                    HStack(spacing: 8) {
                        switch p {
                        case .anthropic:
                            Button("Import Claude Code") {
                                Task {
                                    report(await store.importClaudeCode() == nil && store.accountNotice == nil
                                           ? "No verifiable Claude Code login found on this Mac." : nil)
                                }
                            }
                            Button("Sign in with browser") { store.addAndSignIn(.anthropic) }
                        case .openai:
                            Button("Import Codex CLI") {
                                report(store.importCodexCLI() == nil
                                       ? "No Codex CLI login found on this Mac." : nil)
                            }
                            Button("Sign in with browser") { store.addAndSignIn(.openai) }
                        case .google:
                            Button("Import Antigravity") {
                                Task {
                                    // A login that is already tracked is not a
                                    // missing one; the notice says which it was.
                                    report(await store.importGoogleCLI() == nil && store.accountNotice == nil
                                           ? "No Antigravity or gemini-cli login found on this Mac." : nil)
                                }
                            }
                            Button("Sign in with browser") { store.addAndSignIn(.google) }
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


/// Press feedback for tiny controls: the label squashes while the mouse is
/// down and springs back on release, so the click is acknowledged before
/// anything else happens.
struct PressSquashStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.78 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
