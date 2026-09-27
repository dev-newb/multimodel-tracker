import AppKit
import SwiftUI

/// A native button gives left/right mouse clicks the same action and a stable
/// rectangular target, even when its SwiftUI page content is replaced.
struct PagerArrow: NSViewRepresentable {
    enum Direction { case left, right }
    let direction: Direction
    let label: String
    let action: () -> Void

    func makeNSView(context: Context) -> PagerButton {
        let button = PagerButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.target = button
        button.action = #selector(PagerButton.activate)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        return button
    }
    func updateNSView(_ button: PagerButton, context: Context) {
        button.handler = action
        button.isEnabled = context.environment.isEnabled
        button.image = NSImage(systemSymbolName: direction == .left ? "chevron.left" : "chevron.right", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PagerButton, context: Context) -> CGSize? {
        CGSize(width: 26, height: 26)
    }
}

final class PagerButton: NSButton {
    var handler: (() -> Void)?
    private var rightPressed = false
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func activate() { handler?() }
    override func rightMouseDown(with event: NSEvent) {
        rightPressed = true
        highlight(true)
    }
    override func rightMouseUp(with event: NSEvent) {
        highlight(false)
        defer { rightPressed = false }
        if rightPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { performClick(nil) }
    }
}

extension View {
    func accountNotice(_ store: Store) -> some View {
        alert("Account already tracked", isPresented: Binding(get: { store.accountNotice != nil }, set: { if !$0 { store.accountNotice = nil } })) {
            Button("OK") { store.accountNotice = nil }
        } message: { Text(store.accountNotice ?? "") }
    }
}
