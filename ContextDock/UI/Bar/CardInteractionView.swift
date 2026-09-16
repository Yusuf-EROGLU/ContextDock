import AppKit
import SwiftUI

/// AppKit overlay that owns the card's mouse handling: first-click without activation,
/// hover with an always-active tracking area, and right-click context menus.
struct CardInteractionView: NSViewRepresentable {
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        view.onClick = onClick
        view.onHover = onHover
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onHover = onHover
        nsView.makeMenu = makeMenu
    }

    final class InteractionNSView: NSView {
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        var makeMenu: (() -> NSMenu)?
        private var trackingArea: NSTrackingArea?
        private var pressed = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                showMenu(with: event)
                return
            }
            pressed = true
        }

        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            let location = convert(event.locationInWindow, from: nil)
            if bounds.contains(location) {
                onClick?()
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(with: event)
        }

        private func showMenu(with event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
