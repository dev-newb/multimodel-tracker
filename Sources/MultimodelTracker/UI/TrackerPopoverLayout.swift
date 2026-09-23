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
    static func bounded(_ size: NSSize, screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 800, height: 800)
        return NSSize(width: min(max(size.width.rounded(.up), 1), visible.width - 24),
                      height: min(max(size.height.rounded(.up), 1), visible.height - 24))
    }

    static func resize(_ popover: NSPopover, to proposed: NSSize, anchor: NSView?) {
        let size = bounded(proposed, screen: anchor?.window?.screen)
        guard abs(popover.contentSize.width - size.width) > 0.5 || abs(popover.contentSize.height - size.height) > 0.5 else { return }
        let animated = popover.animates
        popover.animates = false // SwiftUI owns the disclosure animation; no second window animation.
        popover.contentSize = size
        if popover.isShown, let anchor, anchor.window?.isVisible == true {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        popover.animates = animated
    }

    static func resizePanel(_ panel: NSWindow, to proposed: NSSize) {
        let size = bounded(proposed, screen: panel.screen)
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
    }
}
