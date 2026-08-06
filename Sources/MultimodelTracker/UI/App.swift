import SwiftUI
import AppKit

/// Menu-bar-only app: no Dock icon, no main window. The status item shows one
/// badge per provider carrying that vendor's worst account, which is the bit
/// of the reference design worth keeping — you read the numbers without
/// opening anything.
@main
struct MultimodelTrackerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

extension Notification.Name {
    /// Posted by any window that wants to hand focus back to the tray popover.
    static let mmtShowTray = Notification.Name("mmt.showTray")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = Store()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--preview` opens the popover content in a normal window. A menu-bar
        // status item can't be screenshotted or driven by the accessibility
        // API from an unbundled binary, so this is how the UI gets reviewed.
        if CommandLine.arguments.contains("--preview") {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Multimodel Tracker — preview"
            w.contentViewController = NSHostingController(rootView: PopoverView(store: store))
            w.center(); w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        // Size to the content rather than a fixed height — two accounts must
        // not leave the same empty gulf a fixed 520 produced.
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        NotificationCenter.default.addObserver(forName: .mmtShowTray, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.accountsWindow?.close()
                if self?.popover.isShown != true { self?.togglePopover() }
            }
        }

        renderBadges()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.refreshAll()
                self?.renderBadges()
            }
        }
        Task { @MainActor in await store.refreshAll(); renderBadges() }

        if CommandLine.arguments.contains("--bridge-test") {
            Task { @MainActor in
                guard let acct = store.accounts(for: .anthropic).first else {
                    FileHandle.standardError.write("BRIDGE: no anthropic account\n".data(using:.utf8)!); return
                }
                let out = await WebSessionPool.shared.bridgeDiagnostics(for: acct)
                FileHandle.standardError.write("BRIDGE: \(out)\n".data(using:.utf8)!)
            }
        }

        // `--open` pops the panel on launch. A status item can't be clicked by
        // the accessibility API from an unbundled binary, so this is how the
        // popover gets reviewed during development.
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.togglePopover()
            }
        }

        // `--render-maxed <dir>` writes one PNG per MaxedStyle to <dir> and
        // exits. Screenshot-based review captures whatever Space the user is
        // on — this renders offscreen and touches nothing visible.
        if let i = CommandLine.arguments.firstIndex(of: "--render-maxed"),
           CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            for style in MaxedStyle.allCases {
                let view = LimitRow(limit: UsageLimit(key: "codex", label: "Codex · weekly",
                                                      percent: 100, resetsAt: Date().addingTimeInterval(432_000)),
                                    accent: Provider.openai.accent, maxedStyle: style)
                    .frame(width: 300)
                    .padding(24)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("maxed-\(style.rawValue).png"))
                }
            }
            NSApp.terminate(nil)
        }

        // `--render-burn <dir>` — same offscreen review path as --render-maxed.
        if let i = CommandLine.arguments.firstIndex(of: "--render-burn"),
           CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            for style in BurnStyle.allCases {
                var limit = UsageLimit(key: "codex", label: "Codex · weekly", percent: 62,
                                       resetsAt: Date().addingTimeInterval(432_000))
                limit.burning = true
                let view = LimitRow(limit: limit, accent: Provider.openai.accent, burnStyle: style)
                    .frame(width: 300)
                    .padding(24)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("burn-\(style.rawValue).png"))
                }
            }
            NSApp.terminate(nil)
        }

        // `--burn-sim` exercises the ported detector against synthetic pool
        // histories and prints PASS/FAIL per rule. The detector is pure, so
        // this is the whole contract: quiet drift, fallback floor, adaptive
        // trigger, sub-floor jumps, hysteresis cooling, resets in baseline.
        if CommandLine.arguments.contains("--burn-sim") {
            let now = Date()
            func series(_ points: [(minsAgo: Double, v: Double)]) -> [Store.BurnSample] {
                points.map { Store.BurnSample(t: now.addingTimeInterval(-$0.minsAgo * 60), v: $0.v) }
                      .sorted { $0.t < $1.t }
            }
            var results: [(String, Bool)] = []

            // 1. Quiet drift for 3h: never burns.
            var quiet: [(Double, Double)] = []
            for i in 0..<60 { quiet.append((Double(180 - i * 3), 10 + Double(i) * 0.1)) }
            let r1 = Store.evaluateBurn(samples: series(quiet.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: nil)
            results.append(("quiet drift stays cold", r1 == nil))

            // 2. Thin history (<50 pairs) + 9-point jump: fallback floor fires.
            var thin: [(Double, Double)] = []
            for i in 0..<8 { thin.append((Double(30 - i * 3), 20 + Double(i) * 0.2)) }
            thin += [(9, 22), (6, 25), (3, 28), (0, 31)]
            let r2 = Store.evaluateBurn(samples: series(thin.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: nil)
            results.append(("fallback floor (9pt, thin history)", r2 != nil))

            // 3. Adaptive: 3h of jittered ~0.1%/min, then 6 points in 10 min.
            var adaptive: [(Double, Double)] = []
            var v = 5.0
            for i in 0..<56 {
                v += 0.25 + (i % 3 == 0 ? 0.15 : 0.0)   // jittered baseline
                adaptive.append((Double(190 - i * 3), v))
            }
            adaptive += [(9, v + 1.5), (6, v + 3.0), (3, v + 4.5), (0, v + 6.0)]
            let r3 = Store.evaluateBurn(samples: series(adaptive.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: nil)
            results.append(("adaptive trigger (6pt vs quiet baseline)", r3 != nil))

            // 4. Same baseline, 2-point jump: under the 3-point floor.
            var small = adaptive.dropLast(4).map { $0 }
            small += [(9, v + 0.5), (6, v + 1.0), (3, v + 1.5), (0, v + 2.0)]
            let r4 = Store.evaluateBurn(samples: series(small.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: nil)
            results.append(("2pt jump under absolute floor", r4 == nil))

            // 5. Hysteresis: burning entry + quiet window clamps to cooling,
            //    but does NOT extinguish immediately.
            let burningUntil = now.addingTimeInterval(40 * 60)
            let r5 = Store.evaluateBurn(samples: series(quiet.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: burningUntil)
            let clamped = r5.map { $0 > now && $0 <= now.addingTimeInterval(Store.burnCooling + 1) } ?? false
            results.append(("hysteresis cools over 8m, no snap-out", clamped))

            // 6. A weekly reset (big negative delta) in the baseline doesn't
            //    fire and doesn't poison the pairs after it.
            var reset: [(Double, Double)] = []
            for i in 0..<30 { reset.append((Double(200 - i * 3), 60 + Double(i) * 0.3)) }
            reset.append((110, 2))    // reset to near zero
            for i in 0..<30 { reset.append((Double(107 - i * 3), 2 + Double(i) * 0.3)) }
            let r6 = Store.evaluateBurn(samples: series(reset.map { (minsAgo: $0.0, v: $0.1) }),
                                        now: now, currentUntil: nil)
            results.append(("weekly reset ignored", r6 == nil))

            for (name, ok) in results {
                FileHandle.standardError.write("burn-sim \(ok ? "PASS" : "FAIL"): \(name)\n".data(using: .utf8)!)
            }
            let allOK = results.allSatisfy(\.1)
            FileHandle.standardError.write("burn-sim \(allOK ? "ALL PASS" : "FAILURES")\n".data(using: .utf8)!)
            exit(allOK ? 0 : 1)
        }

        // `--import-google` exercises the Antigravity/gemini-cli import from
        // the command line, so the Google path can be verified without
        // driving the panel's button.
        if CommandLine.arguments.contains("--import-google") {
            Task { @MainActor in
                let existing = store.accounts(for: .google).count
                let added = store.importGoogleCLI()
                let outcome = added != nil ? "added"
                    : (existing > 0 ? "already present (\(existing))" : "no credentials found")
                FileHandle.standardError.write("import-google: \(outcome)\n".data(using: .utf8)!)
            }
        }

        // `--accounts` does the same for the Accounts window, which otherwise
        // is only reachable through a click inside the popover.
        if CommandLine.arguments.contains("--accounts") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.openSettings()
            }
        }
    }

    /// Compact per-provider badges: "A 66  O 17". Colour tracks severity, so a
    /// glance is enough — this is the job the reference's coloured squares do.
    private func renderBadges() {
        // Badge metrics. Measured against neighbouring status items, whose ink
        // centres sit at 37.0-38.0 (2x): no baseline shift is needed — the
        // default already lands at 37.0. An earlier baselineOffset:1 pushed it
        // to 35.5, i.e. a point HIGH.
        // The actual defect was a trailing space appended to EVERY part,
        // including the last, which padded the status item's width on the
        // right and left the text hugging the left of its highlight. Parts are
        // joined with a separator instead.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attrs: (NSColor) -> [NSAttributedString.Key: Any] = { colour in
            [.foregroundColor: colour, .font: font]
        }
        let parts = Provider.allCases.compactMap { p -> NSAttributedString? in
            let worst = store.accounts(for: p).compactMap(\.worstPercent).max()
            guard let w = worst else { return nil }
            let colour: NSColor = w >= 90 ? .systemRed : (w >= 75 ? .systemOrange : .labelColor)
            return NSAttributedString(string: "\(p.displayName.prefix(1))\(Int(w))",
                                      attributes: attrs(colour))
        }
        let joined = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { joined.append(NSAttributedString(string: " ", attributes: attrs(.labelColor))) }
            joined.append(part)
        }
        if joined.length == 0 {
            joined.append(NSAttributedString(string: "—"))
        }
        statusItem.button?.attributedTitle = joined
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            store.noteMaxedViewing()
            store.noteBurnViewing()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil,
               let host = popover.contentViewController as? NSHostingController<PopoverView> {
                FileHandle.standardError.write(
                    "popover fitting=\(Int(host.view.fittingSize.height)) content=\(Int(popover.contentSize.height))\n"
                        .data(using: .utf8)!)
            }
        }
    }

    private var accountsWindow: NSWindow?

    @objc func openSettings() {
        // The panel doesn't take key focus, so a transient popover no longer
        // dismisses itself — and popovers outrank a .floating panel, leaving
        // Accounts opening BEHIND the tray window. Close it explicitly.
        if popover.isShown { popover.performClose(nil) }
        if let w = accountsWindow {
            w.placeNearMenuBar(anchor: statusItem.button?.window?.frame)
            w.orderFrontRegardless(); return
        }
        // Spotlight pattern, not a plain window. moveToActiveSpace proved
        // unreliable here — the window kept surfacing on the Space it was born
        // on — and NSApp.activate can itself switch Spaces toward the app's
        // other windows (this app keeps hidden webview hosts). A floating
        // non-activating panel on every Space cannot be on the wrong one, and
        // it takes keystrokes for the nickname fields without activating us.
        // Borderless: no traffic lights, no title bar, not draggable. This
        // belongs under the menu bar like the popover, not parked somewhere.
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isMovable = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.level = .floating
        w.hidesOnDeactivate = false
        let host = NSHostingController(rootView: AccountsView(store: store))
        // Let the hosting controller drive the window height as accounts are
        // added and removed, instead of pinning it.
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        w.setContentSize(host.view.fittingSize)
        w.isReleasedWhenClosed = false
        w.placeNearMenuBar(anchor: statusItem.button?.window?.frame)
        // Order front WITHOUT key status: grabbing key here steals whatever
        // the user is mid-typing elsewhere (it captured a stray keystroke into
        // the nickname field during testing). Clicking a field still focuses
        // it — that's what nonactivatingPanel is for.
        w.orderFrontRegardless()
        accountsWindow = w
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write("accounts window: \(Int(w.frame.width))x\(Int(w.frame.height))\n".data(using: .utf8)!)
        }
    }
}

extension NSWindow {
    /// Drop the window just under the menu bar, horizontally on the anchor
    /// (the status item that was clicked) or, without one, on the mouse —
    /// which for a menu-bar app is where the user actually is. `center()` was
    /// wrong twice over: `NSScreen.main` is stale or nil with no key window,
    /// and mid-screen is a long way from the tray this app lives in.
    func placeNearMenuBar(anchor: NSRect? = nil) {
        let mouse = NSEvent.mouseLocation
        let focus = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(focus, $0.frame, false) })
                ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { center(); return }
        let v = screen.visibleFrame
        let x = min(max(focus.x - frame.width / 2, v.minX + 8), v.maxX - frame.width - 8)
        setFrameOrigin(NSPoint(x: x, y: v.maxY - frame.height - 4))
    }
}
