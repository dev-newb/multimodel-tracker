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

        renderBadges()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderBadges() }
        }
        Task { @MainActor in await store.refreshAll(); renderBadges() }

        // `--open` pops the panel on launch. A status item can't be clicked by
        // the accessibility API from an unbundled binary, so this is how the
        // popover gets reviewed during development.
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    /// Compact per-provider badges: "A 66  O 17". Colour tracks severity, so a
    /// glance is enough — this is the job the reference's coloured squares do.
    private func renderBadges() {
        let parts = Provider.allCases.compactMap { p -> NSAttributedString? in
            let worst = store.accounts(for: p).compactMap(\.worstPercent).max()
            guard let w = worst else { return nil }
            let colour: NSColor = w >= 90 ? .systemRed : (w >= 75 ? .systemOrange : .labelColor)
            return NSAttributedString(
                string: "\(p.displayName.prefix(1))\(Int(w)) ",
                attributes: [.foregroundColor: colour,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        }
        let joined = NSMutableAttributedString()
        parts.forEach { joined.append($0) }
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
        if let w = accountsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Multimodel Tracker — Accounts"
        w.contentViewController = NSHostingController(rootView: AccountsView(store: store))
        w.isReleasedWhenClosed = false
        w.center(); w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        accountsWindow = w
    }
}
