import AppKit

/// Shows the pointing-hand cursor over anything clickable in one of our SwiftUI windows, so
/// buttons, menus, switches and pop-ups read as clickable. It asks the window's accessibility
/// tree what is under the mouse, which covers every control without tagging each one.
final class HandCursor: NSResponder {
    private static var installed: [ObjectIdentifier: HandCursor] = [:]
    private weak var window: NSWindow?
    private var showingHand = false

    static func install(on window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard installed[key] == nil, let view = window.contentView else { return }
        let helper = HandCursor()
        helper.window = window
        // activeAlways: the Note Taker panel floats without being the key window.
        view.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: helper))
        installed[key] = helper
    }

    override func mouseMoved(with event: NSEvent) { update() }
    override func mouseEntered(with event: NSEvent) { update() }
    override func mouseExited(with event: NSEvent) { reset() }

    private func update() {
        guard let view = window?.contentView, window?.attachedSheet == nil else { return reset() }
        if Self.isClickable(view.accessibilityHitTest(NSEvent.mouseLocation)) {
            NSCursor.pointingHand.set()
            showingHand = true
        } else {
            reset()
        }
    }

    private func reset() {
        guard showingHand else { return }
        showingHand = false
        NSCursor.arrow.set()
    }

    private static let roles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
    ]

    /// The element under the mouse is often a button's label or icon, so its parents count too.
    private static func isClickable(_ hit: Any?) -> Bool {
        var element = hit as AnyObject?
        for _ in 0..<4 {
            guard let current = element else { return false }
            if current is NSWindow { return false }
            if let role = current.accessibilityRole?(), roles.contains(role) {
                return current.isAccessibilityEnabled?() ?? true
            }
            element = current.accessibilityParent?() as AnyObject?
        }
        return false
    }
}
