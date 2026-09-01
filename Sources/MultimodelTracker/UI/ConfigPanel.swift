import SwiftUI
import AppKit

/// The Config panel's page navigation, rebuilt on AppKit + Core Animation.
///
/// The accounts list, the settings hub, and each settings section are
/// SEPARATE layer-backed NSHostingViews inside one AppKit container. A push
/// slides two hosting views by animating their frame origins through
/// NSAnimationContext — a Core Animation transaction that runs in the render
/// server, off the main thread, touching no SwiftUI layout per frame. That
/// is what the SwiftUI-side versions could never be: the pages hold
/// AppKit-backed controls (pop-ups, checkboxes, text fields), so animating
/// their offset in SwiftUI meant re-positioning real NSViews on the main
/// thread every frame while five preview canvases competed for it, and the
/// click first re-evaluated the whole tree. Here the click commits one CA
/// transaction and the first frame lands on the next vsync.
@MainActor
final class ConfigNav: ObservableObject {
    /// nil = the hub.
    @Published private(set) var current: ConfigTab? = nil
    var onNavigate: ((ConfigTab?) -> Void)?
    func go(_ target: ConfigTab?) { onNavigate?(target) }
    func setCurrent(_ target: ConfigTab?) { current = target }
}

/// y grows downward, so the panel hangs from the top of whatever window
/// height it happens to have — content never re-centres.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The hosting views are children of the material, so IT must be flipped
/// too — otherwise its y=0 is the bottom and the top-down layout lands the
/// accounts list under the hub.
private final class FlippedEffectView: NSVisualEffectView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ConfigPanelContainer: NSView {
    static let width: CGFloat = 480
    static let slideDuration = 0.12
    static let hubTag = "hub"

    private let material = FlippedEffectView()
    private let top: NSHostingView<AnyView>
    private let pagesClip = FlippedView()
    private let hub: NSHostingView<AnyView>
    private var pages: [ConfigTab: NSHostingView<AnyView>] = [:]
    private let nav: ConfigNav

    private var topHeight: CGFloat = 0
    private var pageHeights: [String: CGFloat] = [:]
    private var areaHeight: CGFloat = 0
    private var sliding = false
    /// Total content height — the window owner matches it, top edge pinned.
    var onHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    init(store: Store, nav: ConfigNav) {
        self.nav = nav
        top = NSHostingView(rootView: AnyView(EmptyView()))
        hub = NSHostingView(rootView: AnyView(EmptyView()))
        for s in ConfigTab.allCases { pages[s] = NSHostingView(rootView: AnyView(EmptyView())) }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 720))
        wantsLayer = true

        // The panel's material and shape live here now, not in SwiftUI.
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        let r: CGFloat = 12
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        material.maskImage = mask
        addSubview(material)

        pagesClip.wantsLayer = true
        pagesClip.layer?.masksToBounds = true
        material.addSubview(top)
        material.addSubview(pagesClip)
        pagesClip.addSubview(hub)
        for s in ConfigTab.allCases { pagesClip.addSubview(pages[s]!) }
        for v in [top, hub] + pages.values { v.wantsLayer = true }

        // Roots are installed after super.init so their callbacks can hold
        // a weak self. Every root reports its own ideal height.
        top.rootView = AnyView(
            AccountsView(store: store, onHeightChange: { [weak self] h in self?.topChanged(h) })
                .frame(maxHeight: .infinity, alignment: .top))
        hub.rootView = AnyView(
            SettingsHubView(nav: nav)
                .reportHeight { [weak self] h in self?.pageChanged(Self.hubTag, h) }
                .frame(maxHeight: .infinity, alignment: .top))
        for s in ConfigTab.allCases {
            pages[s]!.rootView = AnyView(
                SectionPageView(section: s, store: store, nav: nav)
                    .reportHeight { [weak self] h in self?.pageChanged(s.rawValue, h) }
                    .frame(maxHeight: .infinity, alignment: .top))
        }
        nav.onNavigate = { [weak self] t in self?.navigate(to: t) }

        // Starting positions: hub in place, sections parked off the right.
        top.frame = NSRect(x: 0, y: 0, width: Self.width, height: 600)
        hub.frame = NSRect(x: 0, y: 0, width: Self.width, height: 400)
        for s in ConfigTab.allCases {
            pages[s]!.frame = NSRect(x: Self.width, y: 0, width: Self.width, height: 900)
        }
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func topChanged(_ h: CGFloat) {
        guard abs(h - topHeight) > 0.5 else { return }
        topHeight = h
        relayout()
    }

    private func pageChanged(_ tag: String, _ h: CGFloat) {
        guard abs(h - (pageHeights[tag] ?? -1)) > 0.5 else { return }
        pageHeights[tag] = h
        // Follow in-page growth (a picker revealing rows) live, but never
        // mid-slide — the area is held at the larger height until it lands.
        if !sliding, tag == currentTag { areaHeight = h }
        relayout()
    }

    private var currentTag: String { nav.current?.rawValue ?? Self.hubTag }
    private func view(for tab: ConfigTab?) -> NSHostingView<AnyView> { tab.map { pages[$0]! } ?? hub }

    /// Manual layout, top-down. Each hosting view is exactly its content's
    /// height, so the SwiftUI inside is never asked to stretch or squash.
    private func relayout() {
        let w = Self.width
        top.frame = NSRect(x: 0, y: 0, width: w, height: max(topHeight, 1))
        pagesClip.frame = NSRect(x: 0, y: topHeight, width: w, height: max(areaHeight, 1))
        material.frame = NSRect(x: 0, y: 0, width: w, height: topHeight + areaHeight)
        hub.frame.size = NSSize(width: w, height: max(pageHeights[Self.hubTag] ?? 400, 1))
        for s in ConfigTab.allCases {
            pages[s]!.frame.size = NSSize(width: w, height: max(pageHeights[s.rawValue] ?? 900, 1))
        }
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write(
                "layout top.y=\(Int(top.frame.minY)) pages.y=\(Int(pagesClip.frame.minY)) total=\(Int(topHeight + areaHeight))\n"
                    .data(using: .utf8)!)
        }
        onHeightChange?(topHeight + areaHeight)
    }

    /// The push. Pin the visible area to the larger page for the slide, run
    /// one Core Animation transaction moving both hosting views, settle the
    /// area to the destination when it lands. Heights change in discrete
    /// steps only — never interpolated.
    func navigate(to target: ConfigTab?) {
        guard !sliding, target != nav.current else { return }
        let fromView = view(for: nav.current), toView = view(for: target)
        let fromH = pageHeights[currentTag] ?? 0
        let toTag = target?.rawValue ?? Self.hubTag
        let toH = pageHeights[toTag] ?? 0
        sliding = true
        areaHeight = max(fromH, toH)
        relayout()
        let debug = ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil
        let began = Date()
        if debug {
            FileHandle.standardError.write(
                "nav \(currentTag) -> \(toTag) area=\(Int(areaHeight)) from=\(Int(fromH)) to=\(Int(toH))\n"
                    .data(using: .utf8)!)
        }
        let incomingFrom: CGFloat = target == nil ? -Self.width : Self.width
        toView.setFrameOrigin(NSPoint(x: incomingFrom, y: 0))
        nav.setCurrent(target)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            toView.animator().setFrameOrigin(NSPoint(x: 0, y: 0))
            fromView.animator().setFrameOrigin(NSPoint(x: -incomingFrom, y: 0))
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if debug {
                    FileHandle.standardError.write(
                        "nav landed after \(Int(Date().timeIntervalSince(began) * 1000))ms\n".data(using: .utf8)!)
                }
                self.sliding = false
                self.areaHeight = self.pageHeights[toTag] ?? toH
                self.relayout()
            }
        })
    }

    /// Double-click on the panel's background returns to the tray — the same
    /// gesture the SwiftUI root used to carry. Single clicks fall through so
    /// the window stays draggable by its background.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NotificationCenter.default.post(name: .mmtShowTray, object: nil)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - the SwiftUI pages

private struct ReportHeight: ViewModifier {
    let onChange: (CGFloat) -> Void
    func body(content: Content) -> some View {
        content
            .frame(width: ConfigPanelContainer.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { onChange(g.size.height) }
                    .onChange(of: g.size.height) { _, h in onChange(h) }
            })
    }
}

extension View {
    /// Fixed at panel width and its own ideal height, reporting that height.
    func reportHeight(_ f: @escaping (CGFloat) -> Void) -> some View {
        modifier(ReportHeight(onChange: f))
    }
}

/// Hub rows light up on mouse-DOWN, not just on release — the click is
/// acknowledged the instant it happens, which is most of what "responsive"
/// feels like.
struct HubRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.05),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The hub: one compact row per settings section, iOS-Settings style —
/// tinted icon chip, label, chevron.
struct SettingsHubView: View {
    @ObservedObject var nav: ConfigNav

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ConfigTab.allCases) { section in
                Button {
                    nav.go(section)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(section.tint, in: RoundedRectangle(cornerRadius: 6))
                        Text(section.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HubRowStyle())
            }
        }
        .padding(16)
    }
}

/// One drilled-in page: back row, section title, and the section itself.
struct SectionPageView: View {
    let section: ConfigTab
    @ObservedObject var store: Store
    @ObservedObject var nav: ConfigNav
    @ObservedObject private var sounds = Sounds.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    nav.go(nil)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Config").font(.system(size: 12))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Text(section.title.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            switch section {
            case .menuBar: badgeSection
            case .effects: deadBarSection
            case .flashes: flashSection
            case .sounds:  soundSection
            }
        }
    }

    /// Menu-bar appearance. Only the healthy colour is offered: amber at 75%
    /// and red at 90% stay on permanently.
    private var badgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Numbers when healthy").font(.system(size: 12))
                    Text("Amber past 75% and red past 90% either way")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                OptionPicker(width: AccountsView.pickerWidth,
                             options: AccountsView.badgeOptions,
                             selection: Binding(get: { store.badgeTinted },
                                                set: { store.setBadgeTinted($0) }))
            }
        }
        .padding(16)
    }

    /// The alert sounds. Each is independently switchable, can point at the
    /// user's own file, and has its own volume — matching I'm Burning!.
    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SoundKind.allCases) { kind in
                SoundRow(kind: kind, sounds: sounds)
            }
        }
        .padding(16)
    }

    /// The menu-bar flash pickers: one per alert event, previewed the same
    /// way the Flash Lab's inspection view showed them — a dark mock bar at
    /// panel width with the effect looping in the badge's slot.
    private var flashSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The badge fades into the word for exactly as long as that alert's sound file runs.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            ForEach(FlashEvent.allCases) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(event.displayName).font(.system(size: 12))
                        Spacer()
                        OptionPicker(width: AccountsView.pickerWidth,
                                     options: AccountsView.flashOptions(for: event),
                                     selection: Binding(get: { store.flashPicks[event] ?? -1 },
                                                        set: { store.setFlashPick($0, for: event) }))
                    }
                    // Pages stay mounted for instant navigation; only the
                    // visible one runs its preview clocks.
                    FlashPreviewBar(event: event, pick: store.flashPicks[event] ?? -1,
                                    animating: store.uiVisible && nav.current == .flashes)
                }
            }
        }
        .padding(16)
    }

    /// Bar-effect preferences. Each category picks a distribution first —
    /// consistent across pools, or all different at once — and only the
    /// consistent case shows an animation picker: with "all different" the
    /// assignment is derived, so listing specific animations would be a lie.
    private var deadBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("When several are dead").font(.system(size: 12))
                Spacer()
                OptionPicker(width: AccountsView.pickerWidth, options: AccountsView.distributionOptions,
                             selection: Binding(get: { store.maxedVaried },
                                                set: { store.setMaxedVaried($0) }))
            }
            if !store.maxedVaried {
                HStack(spacing: 8) {
                    Text("Dead animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    OptionPicker(width: AccountsView.pickerWidth, options: AccountsView.deadOptions,
                                 selection: Binding(get: { store.maxedFixed },
                                                    set: { store.setMaxedFixed($0) }))
                }
                EffectPreviewRow(width: AccountsView.pickerWidth) {
                    DeadPreview(fixed: MaxedStyle(rawValue: store.maxedFixed))
                }
            }
            HStack(spacing: 8) {
                Text("When several are burning").font(.system(size: 12))
                Spacer()
                OptionPicker(width: AccountsView.pickerWidth, options: AccountsView.distributionOptions,
                             selection: Binding(get: { store.burnVaried },
                                                set: { store.setBurnVaried($0) }))
            }
            if !store.burnVaried {
                HStack(spacing: 8) {
                    Text("Burning animation").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    OptionPicker(width: AccountsView.pickerWidth, options: AccountsView.burnOptions,
                                 selection: Binding(get: { store.burnFixed },
                                                    set: { store.setBurnFixed($0) }))
                }
                EffectPreviewRow(width: AccountsView.pickerWidth) {
                    BurnPreview(fixed: BurnStyle(rawValue: store.burnFixed))
                }
            }
        }
        .padding(16)
    }
}
