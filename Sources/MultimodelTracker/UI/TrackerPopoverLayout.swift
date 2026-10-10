import AppKit
import SwiftUI

/// Measure the document, not the scroll viewport. Its intrinsic height must never
/// escape into NSPopover: AppKit moves an oversized popover away from its anchor.
struct BoundedTrackerScroll<Content: View>: View {
    let maxHeight: CGFloat
    var expanded = true
    @ViewBuilder var content: () -> Content
    @State private var documentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { documentHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in documentHeight = height }
                })
        }
        // .hidden still permits macOS to show indicators when a mouse is attached.
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: expanded ? min(max(documentHeight, 1), maxHeight) : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
    }
}

private struct RevealTrackerDetail: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var revealTrackerDetail: (String) -> Void {
        get { self[RevealTrackerDetail.self] }
        set { self[RevealTrackerDetail.self] = newValue }
    }
}

@MainActor
enum TrackerPopoverLayout {
    private static var animationDeadline: TimeInterval = 0
    private static var resizes: [ObjectIdentifier: ResizeAnimation] = [:]
    private static var requestedSizes: [ObjectIdentifier: NSSize] = [:]

    static func requestedSize(for popover: NSPopover) -> NSSize {
        requestedSizes[ObjectIdentifier(popover)] ?? popover.contentSize
    }

    /// SwiftUI reports the destination layout before its visual animation runs.
    /// Move the window through intermediate sizes instead of jumping there first.
    static func beginAnimation(duration: TimeInterval) {
        animationDeadline = ProcessInfo.processInfo.systemUptime + duration
    }

    @MainActor private final class ResizeAnimation {
        let target: NSSize
        let start: NSSize
        let began = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval
        var timer: Timer?
        init(start: NSSize, target: NSSize, duration: TimeInterval) {
            self.start = start; self.target = target; self.duration = duration
        }
        deinit { timer?.invalidate() }
    }

    private static func setSize(of window: NSWindow, from start: NSSize, to target: NSSize,
                                apply: @escaping (NSSize) -> Void) {
        let key = ObjectIdentifier(window)
        if let running = resizes[key], running.target == target { return }
        resizes.removeValue(forKey: key)?.timer?.invalidate()
        let duration = animationDeadline - ProcessInfo.processInfo.systemUptime
        guard window.isVisible, duration > 0.015,
              abs(start.height - target.height) > 0.5 || abs(start.width - target.width) > 0.5 else {
            apply(target); return
        }
        let animation = ResizeAnimation(start: start, target: target, duration: duration)
        resizes[key] = animation
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak animation, weak window] _ in
            MainActor.assumeIsolated {
                guard let animation, let window else { resizes.removeValue(forKey: key)?.timer?.invalidate(); return }
                let t = min((ProcessInfo.processInfo.systemUptime - animation.began) / animation.duration, 1)
                let eased = 1 - pow(1 - t, 3)
                let size = NSSize(width: animation.start.width + (animation.target.width - animation.start.width) * eased,
                                  height: animation.start.height + (animation.target.height - animation.start.height) * eased)
                window.disableScreenUpdatesUntilFlush()
                apply(size)
                if t >= 1 { resizes.removeValue(forKey: key)?.timer?.invalidate() }
            }
        }
        animation.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// NSStatusBarWindow.screen may be nil even while its frame is on a display.
    /// Resolve the display geometrically before using a generic screen fallback.
    static func screen(for anchor: NSView?) -> NSScreen? {
        if let frame = anchor?.window?.frame {
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(centre, $0.frame, false) }) { return screen }
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return screen }
            // A display-mode change can leave the menu-bar window above the
            // display's current top. Choose its nearest display, not the key app's.
            func distance(_ screen: NSScreen) -> CGFloat {
                let dx = max(screen.frame.minX - centre.x, 0, centre.x - screen.frame.maxX)
                let dy = max(screen.frame.minY - centre.y, 0, centre.y - screen.frame.maxY)
                return dx * dx + dy * dy
            }
            if let nearest = NSScreen.screens.min(by: { distance($0) < distance($1) }) { return nearest }
        }
        return anchor?.window?.screen ?? NSScreen.main
    }

    static func pin(_ popover: NSPopover, to anchor: NSView?) {
        guard popover.isShown, let window = popover.contentViewController?.view.window,
              let itemFrame = anchor?.window?.frame, let screen = screen(for: anchor) else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let x = min(max(itemFrame.midX - frame.width / 2, visible.minX + 8), visible.maxX - frame.width - 8)
        let top = min(itemFrame.minY + 4, visible.maxY + 8)
        let y = max(top - frame.height, visible.minY + 8)
        if abs(frame.minX - x) > 0.5 || abs(frame.minY - y) > 0.5 {
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
    static func bounded(_ size: NSSize, screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 800, height: 800)
        return NSSize(width: min(max(size.width.rounded(.up), 1), visible.width - 24),
                      height: min(max(size.height.rounded(.up), 1), visible.height - 24))
    }

    static func resize(_ popover: NSPopover, to proposed: NSSize, anchor: NSView?) {
        let size = bounded(proposed, screen: screen(for: anchor))
        requestedSizes[ObjectIdentifier(popover)] = size
        if popover.isShown, let window = popover.contentViewController?.view.window {
            let current = popover.contentViewController?.view.bounds.size ?? popover.contentSize
            setSize(of: window, from: current, to: size) { [weak popover, weak anchor] next in
                guard let popover else { return }
                resizeImmediately(popover, to: next, anchor: anchor)
            }
        } else {
            resizeImmediately(popover, to: size, anchor: anchor)
        }
    }

    private static func resizeImmediately(_ popover: NSPopover, to size: NSSize, anchor: NSView?) {
        guard popover.isShown, let view = popover.contentViewController?.view,
              let window = view.window else {
            popover.contentSize = size
            return
        }
        let current = view.bounds.size
        guard abs(current.width - size.width) > 0.01 || abs(current.height - size.height) > 0.01 else { return }
        LayoutTrace.record("before resize", popover: popover, anchor: anchor, proposed: size)
        // Changing NSPopover.contentSize while shown asks AppKit to re-anchor
        // the window. A status-item window with no screen causes a visible
        // excursion to the display edge before pin() can put it back. Resize
        // the existing window in one frame change, keeping its chrome insets.
        let old = window.frame
        let width = size.width + old.width - current.width
        let height = size.height + old.height - current.height
        var next = NSRect(x: old.midX - width / 2, y: old.maxY - height,
                          width: width, height: height)
        if let visible = screen(for: anchor)?.visibleFrame {
            next.origin.x = min(max(next.minX, visible.minX + 8), visible.maxX - next.width - 8)
            next.origin.y = max(next.minY, visible.minY + 8)
        }
        window.setFrame(next, display: false)
        LayoutTrace.record("after resize", popover: popover, anchor: anchor, proposed: size)
    }

    static func resizePanel(_ panel: NSWindow, to proposed: NSSize) {
        let size = bounded(proposed, screen: panel.screen)
        setSize(of: panel, from: panel.contentRect(forFrameRect: panel.frame).size, to: size) { [weak panel] next in
            guard let panel else { return }
            resizePanelImmediately(panel, to: next)
        }
    }

    private static func resizePanelImmediately(_ panel: NSWindow, to size: NSSize) {
        LayoutTrace.recordPanel("before panel resize", panel: panel, proposed: size)
        let old = panel.frame
        let contentFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(old.width - contentFrame.width) > 0.5 || abs(old.height - contentFrame.height) > 0.5 else { return }
        // Preserve the top edge and horizontal centre, including a user's dragged position.
        var next = NSRect(x: old.midX - contentFrame.width / 2, y: old.maxY - contentFrame.height,
                          width: contentFrame.width, height: contentFrame.height)
        if let visible = panel.screen?.visibleFrame {
            next.origin.x = min(max(next.minX, visible.minX + 8), visible.maxX - next.width - 8)
            next.origin.y = max(next.minY, visible.minY + 8)
        }
        panel.setFrame(next, display: false)
        LayoutTrace.recordPanel("after panel resize", panel: panel, proposed: size)
    }
}

/// Explicit opt-in diagnostics for this app's own layout. No account data.
@MainActor
enum LayoutTrace {
    static var enabled: Bool { CommandLine.arguments.contains("--layout-trace") }
    static func record(_ event: String, popover: NSPopover, anchor: NSView?, proposed: CGSize? = nil) {
        guard let index = CommandLine.arguments.firstIndex(of: "--layout-trace"), index + 1 < CommandLine.arguments.count else { return }
        func rect(_ rect: NSRect?) -> Any { rect.map { [ $0.origin.x, $0.origin.y, $0.width, $0.height ] } ?? NSNull() }
        let row: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
            "window": rect(popover.contentViewController?.view.window?.frame),
            "hostingFrame": rect(popover.contentViewController?.view.frame),
            "anchorWindow": rect(anchor?.window?.frame), "anchorBounds": rect(anchor?.bounds),
            "screen": rect(anchor?.window?.screen?.visibleFrame),
            "screens": NSScreen.screens.map { ["frame": rect($0.frame), "visible": rect($0.visibleFrame)] },
            "shown": popover.isShown, "content": [popover.contentSize.width, popover.contentSize.height],
            "proposed": proposed.map { [$0.width, $0.height] } ?? []]
        write(row, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    static func recordPanel(_ event: String, panel: NSWindow, proposed: CGSize? = nil) {
        guard let index = CommandLine.arguments.firstIndex(of: "--layout-trace"), index + 1 < CommandLine.arguments.count else { return }
        let f = panel.frame
        write(["event": event, "time": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
               "window": [f.minX, f.minY, f.width, f.height], "proposed": proposed.map { [$0.width, $0.height] } ?? []],
              to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    private static func write(_ row: [String: Any], to url: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    }
}
