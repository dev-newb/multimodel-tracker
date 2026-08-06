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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var accountsWindow: NSWindow?

    @objc func openSettings() {
        if let w = accountsWindow {
            w.centerOnActiveScreen()
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Multimodel Tracker — Accounts"
        // Without this the window stays glued to the Space it was born on and
        // reopening it later switches nothing visible on the current one.
        w.collectionBehavior = [.moveToActiveSpace]
        let host = NSHostingController(rootView: AccountsView(store: store))
        // Let the hosting controller drive the window height as accounts are
        // added and removed, instead of pinning it.
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        w.setContentSize(host.view.fittingSize)
        w.isReleasedWhenClosed = false
        w.centerOnActiveScreen()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        accountsWindow = w
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write("accounts window: \(Int(w.frame.width))x\(Int(w.frame.height))\n".data(using: .utf8)!)
        }
    }
}

extension NSWindow {
    /// `center()` uses `NSScreen.main` — the screen with the key window, which
    /// for a menu-bar app is stale or nil, so windows kept appearing on the
    /// other display's Space. The mouse is where the user is: the status item
    /// they just clicked lives on every display's menu bar.
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { center(); return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.midY - frame.height / 2))
    }
}
