import SwiftUI
import AppKit

/// A separate, non-activating tooltip avoids clipping at card/scroll boundaries
/// and never changes the tracker window's size or position.
struct ResetExpiryTooltip: NSViewRepresentable {
    let text: String
    let isPresented: Bool

    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ view: HoverView, context: Context) {
        view.text = text
        view.setPresented(isPresented)
    }
    static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.hide() }

    final class HoverView: NSView {
        var text = "" { didSet { if text != oldValue { hide() } } }
        private var panel: NSPanel?
        private var pending: DispatchWorkItem?
        private var closeObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setPresented(_ presented: Bool) {
            guard presented else { hide(); return }
            guard panel == nil, pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pending = nil
                self?.show()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            hide()
            super.viewWillMove(toWindow: newWindow)
        }

        private func show() {
            guard panel == nil, !text.isEmpty, let parent = window, parent.isVisible,
                  let screen = parent.screen else { return }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = 280
            let size = label.sizeThatFits(NSSize(width: 280, height: 1000))
            let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: size.height + 20))
            content.material = .toolTip
            content.state = .active
            content.wantsLayer = true
            content.layer?.cornerRadius = 7
            content.layer?.masksToBounds = true
            label.frame = NSRect(x: 10, y: 10, width: 280, height: size.height)
            content.addSubview(label)
            let tip = NSPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            tip.isReleasedWhenClosed = false
            tip.isOpaque = false
            tip.backgroundColor = .clear
            tip.hasShadow = true
            tip.ignoresMouseEvents = true
            tip.hidesOnDeactivate = true
            tip.level = .popUpMenu
            tip.appearance = parent.effectiveAppearance
            tip.contentView = content
            let anchor = parent.convertToScreen(convert(bounds, to: nil))
            let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
            let x = min(max(anchor.minX, visible.minX), visible.maxX - content.frame.width)
            let below = anchor.minY - content.frame.height - 5
            let y = below >= visible.minY ? below : min(anchor.maxY + 5, visible.maxY - content.frame.height)
            tip.setFrameOrigin(NSPoint(x: x, y: y))
            parent.addChildWindow(tip, ordered: .above)
            tip.orderFront(nil)
            panel = tip
            closeObserver = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification,
                object: nil, queue: .main) { [weak self] _ in self?.hide() }
        }

        func hide() {
            pending?.cancel(); pending = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
            }
            panel = nil
        }
        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
}
