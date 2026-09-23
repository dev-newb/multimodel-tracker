import AppKit
import SwiftUI

/// An opt-in UI regression check. Uses fabricated data and the app's own
/// window events; no network, Keychain, settings writes or other apps.
@MainActor
enum PopoverLayoutSelfTest {
    static func run() async -> Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX + 140,
                                                       y: screen.visibleFrame.maxY - 26, width: 40, height: 24),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        anchorWindow.contentView = anchor
        anchorWindow.orderFrontRegardless()
        let popover = NSPopover(); popover.animates = false
        let fixture = Fixture()
        let root = FixtureView(fixture: fixture, maxHeight: screen.visibleFrame.height - 160) { size in
            DispatchQueue.main.async { TrackerPopoverLayout.resize(popover, to: size, anchor: anchor) }
        }
        let host = NSHostingController(rootView: root); host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: 300)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        defer { popover.close(); anchorWindow.close() }
        await settle()
        guard let window = host.view.window else { return fail("No popover window") }
        window.makeKey()
        let baseline = window.frame
        var minHeight = baseline.height, maxHeight = baseline.height
        func check(_ expanded: Bool) -> Bool {
            let delta = window.frame.height - baseline.height
            guard expanded ? (delta >= 238 && delta <= 242) : abs(delta) < 2 else {
                return fail("Disclosure did not toggle: expanded=\(expanded), height delta=\(delta)")
            }
            let frame = window.frame
            minHeight = min(minHeight, frame.height); maxHeight = max(maxHeight, frame.height)
            guard abs(frame.maxY - baseline.maxY) < 2, abs(frame.midX - baseline.midX) < 2 else {
                return fail("Popover left its anchor: \(baseline) -> \(frame)")
            }
            guard frame.minY >= screen.visibleFrame.minY, frame.height < screen.visibleFrame.height else { return fail("Popover outgrew screen") }
            return true
        }
        guard check(false) else { return false }
        for iteration in 0..<12 {
            press(window, host: host.view, nearEdge: iteration.isMultiple(of: 2))
            await settle()
            guard check(iteration.isMultiple(of: 2)) else { return false }
        }
        // A larger response must not push the arrow or the window beyond its bounds.
        press(window, host: host.view)
        await settle()
        fixture.rows = 100
        await settle()
        guard check(true), maxHeight - minHeight >= 220, maxHeight - minHeight <= 242 else { return fail("Detail area did not remain bounded") }
        // Repeat after the response changes; the arrow must stay reachable.
        for _ in 0..<4 {
            press(window, host: host.view)
            await settle()
            press(window, host: host.view)
            await settle()
            guard check(true) else { return false }
        }
        let panel = NSPanel(contentRect: NSRect(x: baseline.minX, y: baseline.maxY - 300, width: 340, height: 300),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        let panelTop = panel.frame.maxY, panelX = panel.frame.midX
        for height in [540.0, 300, 650, 300] {
            TrackerPopoverLayout.resizePanel(panel, to: NSSize(width: 340, height: height))
            guard abs(panel.frame.maxY - panelTop) < 2, abs(panel.frame.midX - panelX) < 2 else { panel.close(); return fail("Fallback panel lost its top anchor") }
        }
        panel.close()
        print("PASS: 21 disclosure presses, 23→100 model rows, 28pt reachable button, bounded height, stable popover/panel top and horizontal anchor")
        return true
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
    private static func fail(_ message: String) -> Bool { print("FAIL: \(message)"); return false }
    /// Dispatch real mouse down/up events to this test window. The fixture has
    /// a fixed 40pt footer; the disclosure's full-width 28pt button is above it.
    /// Alternate the left edge and centre to test more than the chevron glyph.
    private static func press(_ window: NSWindow, host: NSView, nearEdge: Bool = false) {
        let fromBottom: CGFloat = 40 + 14
        let point = NSPoint(x: nearEdge ? 20 : host.bounds.midX,
                            y: host.isFlipped ? host.bounds.maxY - fromBottom : fromBottom)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private final class Fixture: ObservableObject {
        @Published var rows = 23
        let account = Account(provider: .google, label: "Layout fixture", limits: [
            UsageLimit(key: "test", label: "Gemini weekly", percent: 25, resetsAt: nil)])
    }
    private struct FixtureView: View {
        @ObservedObject var fixture: Fixture
        let maxHeight: CGFloat
        let sizeChanged: (CGSize) -> Void
        var body: some View {
            VStack(spacing: 0) {
                Text("Layout regression check").frame(height: 40)
                BoundedTrackerScroll(maxHeight: maxHeight) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Google · 23-model fixture").padding(.top, 10)
                        ModelUsageDisclosure(account: fixture.account, accent: .blue, preview:
                            UsageDetails(title: "Model quota used", rows: (0..<fixture.rows).map { .init(model: "Model \($0 + 1)", value: Double($0 % 100)) },
                                         unit: "quotaPercent", note: "Fabricated regression fixture."))
                    }.padding(.horizontal, 16)
                }
                Text("Footer").frame(height: 40)
            }
            .frame(width: 340).fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.onAppear { sizeChanged(g.size) }.onChange(of: g.size) { _, size in sizeChanged(size) }
            })
        }
    }
}
