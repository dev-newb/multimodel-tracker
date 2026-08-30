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
    /// Fired by the Store when an alert event lands; userInfo carries the
    /// event and the flash style to play on the status item.
    static let mmtFlashAlert = Notification.Name("mmt.flashAlert")
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
        flash = FlashController(statusItem: statusItem)

        NotificationCenter.default.addObserver(forName: .mmtFlashAlert, object: nil,
                                               queue: .main) { [weak self] note in
            let raw = note.userInfo?["event"] as? String
            let style = note.userInfo?["style"] as? Int ?? 0
            Task { @MainActor in
                guard let self, let raw, let event = FlashEvent(rawValue: raw) else { return }
                self.beginFlash(event: event, style: style)
            }
        }

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

        // `--cursor-probe` walks the pointer across the open panel and reports
        // which cursor is actually live at each point. Guessing at the source
        // of a stray cursor twice was two attempts too many.
        if CommandLine.arguments.contains("--cursor-probe") {
            Task { @MainActor in
                self.openSettings()
                try? await Task.sleep(for: .seconds(1))
                guard let win = self.accountsWindow else {
                    FileHandle.standardError.write("probe: no panel\n".data(using: .utf8)!); exit(1)
                }
                let saved = NSEvent.mouseLocation
                // currentSystem returns a RECONSTRUCTED cursor, never the
                // singleton, so identity comparison always says "other".
                // Fingerprint by image bytes + hotspot instead.
                func fingerprint(_ c: NSCursor) -> String {
                    let tiff = c.image.tiffRepresentation ?? Data()
                    var h: UInt64 = 0xcbf29ce484222325
                    for b in tiff { h = (h ^ UInt64(b)) &* 0x100000001b3 }
                    return "\(String(h, radix: 36))@\(Int(c.hotSpot.x)),\(Int(c.hotSpot.y))"
                }
                let catalogue: [(NSCursor, String)] = [
                    (.arrow, "arrow"), (.iBeam, "iBeam"),
                    (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown"),
                    (.resizeLeft, "resizeLeft"), (.resizeRight, "resizeRight"),
                    (.resizeUp, "resizeUp"), (.resizeDown, "resizeDown"),
                    (.pointingHand, "pointingHand"), (.crosshair, "crosshair"),
                    (.openHand, "openHand"), (.closedHand, "closedHand"),
                    (.operationNotAllowed, "notAllowed"),
                    (.iBeamCursorForVerticalLayout, "iBeamVertical"),
                    (.dragCopy, "dragCopy"), (.dragLink, "dragLink"),
                    (.contextualMenu, "contextualMenu"),
                ]
                var byPrint: [String: String] = [:]
                for (c, n) in catalogue { byPrint[fingerprint(c)] = n }
                func name(_ c: NSCursor?) -> String {
                    guard let c else { return "nil" }
                    let fp = fingerprint(c)
                    return byPrint[fp] ?? "UNKNOWN[\(fp) size=\(Int(c.image.size.width))x\(Int(c.image.size.height))]"
                }
                let f = win.frame
                var out = "probe: panel \(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY)) key=\(win.isKeyWindow) active=\(NSApp.isActive)\n"
                // Screen coords are bottom-left origin; walk down from the top.
                for dy in stride(from: 20.0, through: min(f.height - 10, 420), by: 40) {
                    let pt = CGPoint(x: f.midX, y: f.maxY - dy)
                    // CGWarp uses top-left origin.
                    // Warping does NOT drive tracking areas; posting real
                    // mouseMoved events does, and tracking areas are what set
                    // these cursors. Step in so enter/exit fire on the way.
                    let h = NSScreen.main?.frame.height ?? 1000
                    for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                        let y = pt.y + (1 - step) * 30
                        let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                         mouseCursorPosition: CGPoint(x: pt.x, y: h - y),
                                         mouseButton: .left)
                        ev?.post(tap: .cghidEventTap)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    // What the governor decided, and the AppKit chain under
                    // the pointer that made it decide that — the ground truth
                    // for "SwiftUI's TextField is backed by NSTextField".
                    let want = self.desiredCursor(at: NSEvent.mouseLocation)
                    var chain: [String] = []
                    var v = self.hitView(at: NSEvent.mouseLocation)
                    while let cur = v, chain.count < 4 {
                        chain.append(String(describing: type(of: cur)))
                        v = cur.superview
                    }
                    out += "  y-\(Int(dy)): system=\(name(NSCursor.currentSystem))"
                        + " want=\(want.map { $0 === NSCursor.iBeam ? "iBeam" : "arrow" } ?? "nil")"
                        + " hit=\(chain.joined(separator: "<"))\n"
                    // Flicker check: with the pointer still, sample fast. More
                    // than one distinct cursor here means something is still
                    // fighting.
                    var seen = Set<String>()
                    for _ in 0..<12 {
                        if let c = NSCursor.currentSystem { seen.insert(name(c)) }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if seen.count > 1 { out += "    FLICKER: \(seen.sorted().joined(separator: ", "))\n" }
                }
                out += "  --- windows owned by this app:\n"
                for win in NSApp.windows {
                    let fr = win.frame
                    out += "    \(type(of: win)) visible=\(win.isVisible) onScreen=\(win.isOnActiveSpace)"
                        + " alpha=\(win.alphaValue) ignoresMouse=\(win.ignoresMouseEvents)"
                        + " level=\(win.level.rawValue)"
                        + " frame=\(Int(fr.minX)),\(Int(fr.minY)) \(Int(fr.width))x\(Int(fr.height))\n"
                }
                let back = CGPoint(x: saved.x, y: (NSScreen.main?.frame.height ?? 1000) - saved.y)
                CGWarpMouseCursorPosition(back)
                FileHandle.standardError.write(out.data(using: .utf8)!)
                exit(0)
            }
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

        // `--loopback-test` exercises the OAuth redirect catcher end to end
        // without a browser: bind an ephemeral port, hit ourselves with the
        // redirect, expect the code back — and a wrong state rejected.
        if CommandLine.arguments.contains("--loopback-test") {
            Task {
                func hit(_ port: UInt16, query: String) async {
                    _ = try? await URLSession.shared.data(
                        from: URL(string: "http://localhost:\(port)/callback?\(query)")!)
                }
                do {
                    let good = try LoopbackCatcher(port: 0, expectedState: "st4te")
                    let port = try await good.ready()
                    async let code = good.awaitCode()
                    await hit(port, query: "code=c0de&state=st4te")
                    let got = try await code
                    var pass = got == "c0de"
                    FileHandle.standardError.write(
                        "loopback ephemeral-port \(port): code=\(got) \(pass ? "PASS" : "FAIL")\n".data(using: .utf8)!)

                    let strict = try LoopbackCatcher(port: 0, expectedState: "right")
                    let port2 = try await strict.ready()
                    async let code2 = strict.awaitCode()
                    await hit(port2, query: "code=c0de&state=wrong")
                    do {
                        _ = try await code2
                        pass = false
                        FileHandle.standardError.write("loopback state-mismatch: accepted — FAIL\n".data(using: .utf8)!)
                    } catch {
                        FileHandle.standardError.write("loopback state-mismatch: rejected — PASS\n".data(using: .utf8)!)
                    }
                    exit(pass ? 0 : 1)
                } catch {
                    FileHandle.standardError.write("loopback FAIL: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
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

        // `--flash <reset|banked|burn>` plays that alert's flash (and sound)
        // on the live status item shortly after launch — the only way to see
        // the real menu-bar rendering without waiting for a genuine alert.
        if let i = CommandLine.arguments.firstIndex(of: "--flash"),
           CommandLine.arguments.indices.contains(i + 1),
           let event = FlashEvent(rawValue: CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                Sounds.shared.play(event.soundKind)
                self.beginFlash(event: event, style: self.store.nextFlashStyle(for: event))
            }
        }

        // `--render-flash <dir>` writes one PNG per event x style, mid-flash,
        // through the same offscreen review path as --render-maxed.
        if let i = CommandLine.arguments.firstIndex(of: "--render-flash"),
           CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            for event in FlashEvent.allCases {
                for style in 0..<FlashEvent.styleCount {
                    let view = FlashFrameView(event: event, style: style, t: 2.4, k: 1,
                                              width: 220, height: 40, scale: 1.8, darkBar: true)
                        .background(Color(red: 0.09, green: 0.082, blue: 0.10))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("flash-\(event.rawValue)-\(style).png"))
                    }
                }
            }
            NSApp.terminate(nil)
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
        let joined = NSMutableAttributedString()
        for (i, seg) in badgeSegments().enumerated() {
            if i > 0 { joined.append(NSAttributedString(string: " ", attributes: attrs(.labelColor))) }
            joined.append(NSAttributedString(string: seg.text, attributes: attrs(seg.colour)))
        }
        if joined.length == 0 {
            joined.append(NSAttributedString(string: "—"))
        }
        statusItem.button?.attributedTitle = joined
    }

    /// The badge's segments — one per provider with data. Amber at 75 and
    /// red at 90 are permanent: severity is the point of the badge and must
    /// not be switchable off; the only choice is what a HEALTHY number looks
    /// like (vendor accent, or plain white). Shared by the attributed title
    /// and the flash frames so the two can never disagree.
    private func badgeSegments() -> [(text: String, colour: NSColor)] {
        Provider.allCases.compactMap { p in
            let worst = store.accounts(for: p).compactMap(\.worstPercent).max()
            guard let w = worst else { return nil }
            let healthy: NSColor = store.badgeTinted ? p.nsAccent : .labelColor
            let colour: NSColor = w >= 90 ? .systemRed
                                 : (w >= 75 ? .systemOrange : healthy)
            return ("\(p.displayName.prefix(1))\(Int(w))", colour)
        }
    }

    private var flash: FlashController?

    private func beginFlash(event: FlashEvent, style: Int) {
        guard let flash else { return }
        let parts = badgeSegments().map { ($0.text, Color(nsColor: $0.colour)) }
        flash.flash(event: event, style: style, badgeParts: parts,
                    duration: Sounds.shared.duration(for: event.soundKind)) { [weak self] in
            self?.renderBadges()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); store.setUIVisible(false) }
        else {
            store.setUIVisible(true)
            startCursorGovernor()
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
        stopCursorGovernor()
        stopWatchingOutsideClick()
        accountsHost = nil
        accountsWindow = nil
        store.setUIVisible(popover.isShown)
    }

    func popoverDidClose(_ notification: Notification) {
        if accountsWindow == nil { stopCursorGovernor() }
        // Accounts may still be open; only stop the clocks if nothing is up.
        store.setUIVisible(accountsWindow?.isVisible == true)
    }

    private var accountsWindow: NSWindow?
    /// Retains the panel's hosting controller — contentView alone doesn't.
    private var accountsHost: NSViewController?

    /// The actual resize, top edge pinned — the panel hangs from the menu
    /// bar, so growth and shrink happen at the bottom. Called for discrete
    /// changes only (tab switch, account added or removed); nothing animates.
    private func applyPanelHeight(_ h: CGFloat) {
        guard h > 1 else { return }
        guard let w = accountsWindow, abs(w.frame.height - h) > 0.3 else { return }
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write(
                "panel-h \(String(format: "%.3f", Date().timeIntervalSince1970)) \(Int(h))\n"
                    .data(using: .utf8)!)
        }
        var f = w.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        // display: false — let drawing happen on the normal cycle instead of
        // forcing a synchronous recomposite; the region being revealed or
        // trimmed is transparent anyway. The synchronous version added a
        // visible beat between the click and the first motion.
        w.setFrame(f, display: false)
        // A transparent window's shadow is computed from its drawn pixels;
        // after the content's shape changed under a static frame, recompute
        // once here rather than every frame.
        w.invalidateShadow()
    }

    /// Live only while the Accounts panel is open.
    private var outsideClickMonitors: [Any] = []
    private var arrowMonitors: [Any] = []
    private var arrowTimer: Timer?

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
                // Anything but the panel itself. (Sign-in used to spawn its
                // own window here; both vendors go through the real browser
                // now, so ours is the only window to spare.)
                guard event.window !== panel else { return }
                // Still our app, so the popover will survive: go back to the
                // tracker, exactly like the back button.
                self.closeAccountsPanel(returningToTracker: true)
            }
            return event
        }
        outsideClickMonitors = [global, local].compactMap { $0 }
        _ = panel
    }

    /// The cursor policy: the I-beam over editable text — the nickname
    /// fields, the one place typing happens — and the plain arrow everywhere
    /// else. Decided by hit-testing what is actually under the pointer.
    ///
    /// This replaces forcing the arrow everywhere, which is what the flicker
    /// WAS. The old timer compared `NSCursor.currentSystem` to the arrow by
    /// object identity; currentSystem returns a RECONSTRUCTED cursor, never
    /// the singleton, so the check always read "different" and the arrow was
    /// re-set every 80ms — colliding forever with the I-beam the text fields
    /// push through their own tracking areas. Text bar, arrow, text bar. The
    /// governor ends the fight instead of trying to win it faster: over a
    /// field the I-beam is the DESIRED cursor and nothing gets contradicted;
    /// elsewhere nothing else pushes, so one corrective set() is stable.
    private func startCursorGovernor() {
        stopCursorGovernor()
        // Local AND global: the local monitor only sees events routed to this
        // app, and this is an .accessory app whose panel does not activate it
        // — hovering in from another app can leave that app's cursor showing
        // over ours. The global monitor catches exactly that case. Enforcing
        // hops to the next runloop pass so it lands AFTER any cursorUpdate
        // the event is about to trigger, not before it.
        let apply: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.enforceCursor() }
        }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate]
        let local = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            apply(); return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: types) { _ in apply() }
        arrowMonitors = [local, global].compactMap { $0 }
        // Backstop for cursors set with the pointer perfectly still (a
        // relayout can do that). Idle ticks are free: enforceCursor touches
        // the cursor only when the live one genuinely differs.
        arrowTimer?.invalidate()
        arrowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceCursor() }
        }
    }

    /// The deepest AppKit view under the pointer, in whichever of our
    /// windows contains it.
    private func hitView(at p: NSPoint) -> NSView? {
        var target: NSWindow?
        if let w = accountsWindow, w.isVisible, w.frame.contains(p) { target = w }
        else if popover?.isShown == true,
                let w = popover.contentViewController?.view.window, w.frame.contains(p) { target = w }
        guard let win = target, let content = win.contentView else { return nil }
        let wp = win.convertPoint(fromScreen: p)
        let root = content.superview ?? content
        return root.hitTest(root.convert(wp, from: nil))
    }

    /// Nil = the pointer is not over our UI; leave the cursor alone.
    func desiredCursor(at p: NSPoint) -> NSCursor? {
        guard pointerIsOverOurUI() else { return nil }
        var v = hitView(at: p)
        while let cur = v {
            // NSText covers the field editor that appears while editing;
            // NSTextField is the resting field (SwiftUI's TextField is backed
            // by one). Both mean "editable text here".
            if cur is NSText { return .iBeam }
            if let tf = cur as? NSTextField, tf.isEditable { return .iBeam }
            v = cur.superview
        }
        return .arrow
    }

    private func enforceCursor() {
        guard let want = desiredCursor(at: NSEvent.mouseLocation) else { return }
        // Fingerprint by image bytes + hotspot — the probe's trick, promoted
        // to production, because identity comparison against currentSystem
        // can never succeed.
        let wantPrint = want === NSCursor.iBeam ? Self.iBeamPrint : Self.arrowPrint
        if let live = NSCursor.currentSystem, Self.cursorFingerprint(live) == wantPrint { return }
        want.set()
    }

    private static let arrowPrint = cursorFingerprint(.arrow)
    private static let iBeamPrint = cursorFingerprint(.iBeam)
    static func cursorFingerprint(_ c: NSCursor) -> String {
        let tiff = c.image.tiffRepresentation ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in tiff { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "\(String(h, radix: 36))@\(Int(c.hotSpot.x)),\(Int(c.hotSpot.y))"
    }

    /// True when the pointer sits inside any window this app is showing —
    /// the Config panel or the tray popover.
    private func pointerIsOverOurUI() -> Bool {
        let p = NSEvent.mouseLocation
        if let w = accountsWindow, w.isVisible, w.frame.contains(p) { return true }
        if popover?.isShown == true,
           let w = popover.contentViewController?.view.window, w.frame.contains(p) { return true }
        return false
    }

    private func stopCursorGovernor() {
        for m in arrowMonitors { NSEvent.removeMonitor(m) }
        arrowMonitors = []
        arrowTimer?.invalidate(); arrowTimer = nil
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

        // A tall creation rect so the panel opens near its real height; the
        // coordinator corrects it to the exact content height on first layout
        // (well within the first frame), so a placeholder close to typical
        // avoids a visible jump on open.
        let w = AccountsPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
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
        // The view is installed directly, NOT as contentViewController, and
        // with NO hosting sizing options: the view measures itself
        // post-layout and reports each discrete height (open, tab switch,
        // account add/remove); the window matches, top edge pinned.
        // Top-aligned explicitly: if the window is momentarily taller than
        // the content, SwiftUI's default would CENTRE the content, making
        // the visible panel slide around.
        let host = NSHostingController(rootView:
            AccountsView(store: store, onHeightChange: { [weak self] h in
                self?.applyPanelHeight(h)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        host.sizingOptions = []
        w.contentView = host.view
        accountsHost = host
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
        // tracking-area pushes reconciled by the cursor governor.
        w.disableCursorRects()
        w.acceptsMouseMovedEvents = true
        NSCursor.arrow.set()
        w.delegate = self
        accountsWindow = w
        watchForOutsideClick(w)
        startCursorGovernor()
        // Closing the previous panel above flipped this false via
        // windowWillClose; the panel is visible now, so re-assert it.
        store.setUIVisible(true)
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write("accounts window: \(Int(w.frame.width))x\(Int(w.frame.height)) key=\(w.canBecomeKey)\n".data(using: .utf8)!)
            // Scroll geometry: is the accounts section hugging its content or
            // stretched to the cap? (documentView vs scroll frame heights)
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView {
                    let doc = sv.documentView?.frame.height ?? -1
                    FileHandle.standardError.write(
                        "  scroll \(type(of: sv)) frame=\(Int(sv.frame.height)) doc=\(Int(doc))\n".data(using: .utf8)!)
                }
                v.subviews.forEach(walk)
            }
            if let c = w.contentView { walk(c) }
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

    /// cursorUpdate is the channel AppKit controls use to push their own
    /// cursors (tracking areas — the half disableCursorRects can't reach).
    /// Swallowing it here means nothing inside the panel can set a cursor at
    /// all; the governor in AppDelegate is the single owner, so there is no
    /// second writer left to flicker against. The governor still SEES these
    /// events — its monitors observe them before dispatch reaches us.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .cursorUpdate { return }
        super.sendEvent(event)
    }
}
