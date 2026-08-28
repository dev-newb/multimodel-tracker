import SwiftUI
import AppKit
import WebKit

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
    /// The badge is AppKit, not SwiftUI, so a settings change has to tell it
    /// to redraw — it observes nothing.
    static let mmtBadgeStyleChanged = Notification.Name("mmt.badgeStyleChanged")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
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
        // Transient popovers dismiss themselves when the user clicks away, so
        // the delegate is the only reliable place to learn they closed.
        popover.delegate = self
        // Size to the content rather than a fixed height — two accounts must
        // not leave the same empty gulf a fixed 520 produced.
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        NotificationCenter.default.addObserver(forName: .mmtBadgeStyleChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.renderBadges() }
        }

        NotificationCenter.default.addObserver(forName: .mmtShowTray, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.accountsWindow?.close()
                if self?.popover.isShown != true { self?.togglePopover() }
            }
        }

        renderBadges()
        timer = Timer.scheduledTimer(withTimeInterval: Store.pollInterval, repeats: true) { [weak self] _ in
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

        // `--google-modes` fetches BOTH Google surfaces and prints them, so
        // the per-model path can be proved against the legacy buckets.
        if CommandLine.arguments.contains("--google-modes") {
            Task { @MainActor in
                guard let acct = store.accounts(for: .google).first else {
                    FileHandle.standardError.write("no google account\n".data(using: .utf8)!); exit(1)
                }
                for mode in GoogleAuthMode.allCases {
                    do {
                        let u = try await GoogleAdapterImpl(mode: mode).fetch(account: acct)
                        var out = "\n[\(mode.displayName)] plan=\(u.plan ?? "-") rows=\(u.limits.count)\n"
                        for l in u.limits {
                            out += "   \(l.label): \(l.percent.map { String(format: "%.1f%%", $0) } ?? "-")"
                                + "  \(l.resetText)\n"
                        }
                        FileHandle.standardError.write(out.data(using: .utf8)!)
                    } catch {
                        FileHandle.standardError.write("\n[\(mode.displayName)] FAILED: \(error)\n".data(using: .utf8)!)
                    }
                }
                exit(0)
            }
        }

        // `--render-tip <dir>` renders a row with the tooltip forced visible,
        // so its size and placement can be checked without a real mouse.
        if let i = CommandLine.arguments.firstIndex(of: "--render-tip"),
           CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let view = LimitRow(limit: UsageLimit(key: "5h", label: "5-hour limit", percent: 6,
                                                  resetsAt: Date().addingTimeInterval(4 * 3600 + 21 * 60)),
                                accent: Provider.anthropic.accent, forceHover: true)
                .frame(width: 300)
                .padding(24)
                .background(Color(red: 0.13, green: 0.13, blue: 0.14))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("tip.png"))
            }
            NSApp.terminate(nil)
        }

        // `--render-settings <dir>` renders the Accounts panel offscreen.
        // Screenshotting it competes with whatever Rich is doing on screen.
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"),
           CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let renderer = ImageRenderer(content:
                AccountsView(store: store).frame(width: 480)
                    .background(Color(red: 0.13, green: 0.13, blue: 0.14)))
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("settings.png"))
            }
            FileHandle.standardError.write(
                "pickerWidth=\(AccountsView.pickerWidth)\n".data(using: .utf8)!)
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

        // `--recover` rebuilds accounts from surviving credentials.
        if CommandLine.arguments.contains("--recover") {
            Task { @MainActor in
                let notes = store.recoverAccounts()
                await store.refreshAll()
                let text = notes.isEmpty ? "nothing to recover" : notes.joined(separator: "\n  ")
                FileHandle.standardError.write("recover:\n  \(text)\n".data(using: .utf8)!)
                exit(0)
            }
        }

        // `--purge-store <uuid>` deletes an orphaned per-account WebKit data
        // store through the sanctioned API (shell deletion under ~/Library is
        // rightly guarded on this Mac).
        if let i = CommandLine.arguments.firstIndex(of: "--purge-store"),
           CommandLine.arguments.indices.contains(i + 1),
           let id = UUID(uuidString: CommandLine.arguments[i + 1]) {
            if #available(macOS 14.0, *) {
                WKWebsiteDataStore.remove(forIdentifier: id) { error in
                    FileHandle.standardError.write(
                        "purge-store \(id): \(error.map { "\($0)" } ?? "ok")\n".data(using: .utf8)!)
                    exit(0)
                }
            } else { exit(1) }
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
            // Amber at 75 and red at 90 are permanent: severity is the point
            // of the badge and must not be switchable off. The only choice is
            // what a HEALTHY number looks like — vendor accent, or plain
            // white as it was originally.
            let healthy: NSColor = store.badgeTinted ? p.nsAccent : .labelColor
            let colour: NSColor = w >= 90 ? .systemRed
                                 : (w >= 75 ? .systemOrange : healthy)
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
        if popover.isShown { popover.performClose(nil); store.setUIVisible(false) }
        else {
            store.setUIVisible(true)
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

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === accountsWindow else { return }
        // A text field pushes the I-beam via a tracking area. Destroying the
        // panel while the pointer is inside one tears that area down without
        // ever delivering mouseExited, so the I-beam is left pushed and
        // follows the user around the desktop. Put the arrow back by hand.
        NSCursor.arrow.set()
        stopWatchingArrowCursor()
        stopWatchingOutsideClick()
        accountsWindow = nil
        store.setUIVisible(popover.isShown)
    }

    func popoverDidClose(_ notification: Notification) {
        // Accounts may still be open; only stop the clocks if nothing is up.
        store.setUIVisible(accountsWindow?.isVisible == true)
    }

    private var accountsWindow: NSWindow?
    /// Live only while the Accounts panel is open.
    private var outsideClickMonitors: [Any] = []
    private var arrowMonitor: Any?

    /// Click-outside-to-dismiss. A non-activating panel never loses key the
    /// way an ordinary window does, so resignKey can't drive this — the click
    /// has to be watched for directly. Two monitors are needed: the global one
    /// sees clicks in OTHER apps, the local one sees clicks elsewhere in this
    /// app (the status item, the popover).
    private func watchForOutsideClick(_ panel: NSWindow) {
        stopWatchingOutsideClick()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click in ANOTHER app activates it. A .transient popover
            // dismisses itself the instant we lose focus, so "go back to the
            // tracker" here would open the popover and kill it in the same
            // breath. Just dismiss; the user is somewhere else now.
            Task { @MainActor in self?.closeAccountsPanel(returningToTracker: false) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, let panel = self.accountsWindow else { return }
                // Not the panel itself, and not a sign-in window it spawned.
                guard event.window !== panel,
                      !SignInWindowController.owns(event.window) else { return }
                // Still our app, so the popover will survive: go back to the
                // tracker, exactly like the back button.
                self.closeAccountsPanel(returningToTracker: true)
            }
            return event
        }
        outsideClickMonitors = [global, local].compactMap { $0 }
        _ = panel
    }

    /// Forces the arrow back after every pointer move inside the panel.
    ///
    /// A local monitor sees the event BEFORE the view does, so setting the
    /// cursor here directly would just be overwritten by the control's own
    /// cursorUpdate a moment later. Hopping to the next runloop pass puts our
    /// set AFTER theirs, which is what actually makes it stick.
    private func watchForArrowCursor(_ panel: NSWindow) {
        stopWatchingArrowCursor()
        arrowMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate]
        ) { [weak self] event in
            if event.window === self?.accountsWindow {
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
            return event
        }
        _ = panel
    }

    private func stopWatchingArrowCursor() {
        if let m = arrowMonitor { NSEvent.removeMonitor(m) }
        arrowMonitor = nil
    }

    private func stopWatchingOutsideClick() {
        for m in outsideClickMonitors { NSEvent.removeMonitor(m) }
        outsideClickMonitors = []
    }

    /// Returning to the tracker posts the same notification the back button
    /// posts, so the two stay in step by construction — one path, not two
    /// that can drift apart.
    private func closeAccountsPanel(returningToTracker: Bool) {
        if returningToTracker {
            NotificationCenter.default.post(name: .mmtShowTray, object: nil)
        } else {
            accountsWindow?.close()
        }
    }

    @objc func openSettings() {
        // Popovers outrank a .floating panel, so a visible popover would sit
        // on top of the panel we are about to show.
        if popover.isShown { popover.performClose(nil) }
        store.setUIVisible(true)

        // Built fresh every time rather than retained and re-shown. A retained
        // window belongs to the Space it was created on; recreating it here
        // means it always appears on the Space the user is on WITHOUT
        // canJoinAllSpaces, which made it follow them everywhere instead.
        accountsWindow?.close()

        let w = AccountsPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        // Draggable by its background: it has no title bar to grab, and a
        // sign-in window can land underneath it.
        w.isMovable = true
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        // Deliberately NOT canJoinAllSpaces — that is what made it follow the
        // user across workspaces.
        w.collectionBehavior = [.fullScreenAuxiliary]
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
        // Key, but WITHOUT activating the app: a borderless panel refuses key
        // status by default, and without it the nickname fields silently
        // swallow every keystroke — renaming an account was impossible.
        w.makeKeyAndOrderFront(nil)
        // Cursor rects are only HALF the story: disableCursorRects blocks
        // rects, but AppKit controls set their cursors through tracking areas
        // (cursorUpdate:), which it does not touch — which is why disabling
        // rects alone changed nothing. Both are handled: rects off here, and
        // cursorUpdate overridden by the monitor in watchForArrowCursor.
        w.disableCursorRects()
        w.acceptsMouseMovedEvents = true
        NSCursor.arrow.set()
        w.delegate = self
        accountsWindow = w
        watchForOutsideClick(w)
        watchForArrowCursor(w)
        // Closing the previous panel above flipped this false via
        // windowWillClose; the panel is visible now, so re-assert it.
        store.setUIVisible(true)
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write("accounts window: \(Int(w.frame.width))x\(Int(w.frame.height)) key=\(w.canBecomeKey)\n".data(using: .utf8)!)
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


/// A borderless panel that can still take keyboard focus. NSWindow refuses
/// key status for borderless windows, which left every text field in the
/// Accounts panel unable to receive a single keystroke.
final class AccountsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
