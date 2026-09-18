import AppKit
import SwiftUI

/// Identifies what an interaction overlay stands for: a bar item, or one member icon inside a
/// group card.
enum InteractionTarget: Hashable {
    case item(BarItemID)
    case member(WindowSessionID, in: GroupID)

    var draggedItem: BarItemID {
        switch self {
        case .item(let id): return id
        case .member(let window, _): return .window(window)
        }
    }
}

/// Callbacks for drag gestures, routed to the drag coordinator by the bar.
struct DragHandlers {
    var began: (InteractionTarget, NSPoint) -> Void
    var moved: (NSPoint) -> Void
    var ended: (NSPoint, Bool) -> Void
}

/// AppKit overlay that owns a card's (or member icon's) mouse handling: first-click without
/// activation, hover with an always-active tracking area, right-click menus, and drag start.
struct CardInteractionView: NSViewRepresentable {
    var target: InteractionTarget
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var makeMenu: () -> NSMenu
    var drag: DragHandlers?
    /// Reports when a context menu opens/closes so the bar does not auto-hide underneath it.
    var onMenuVisibility: ((Bool) -> Void)?

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InteractionNSView) {
        view.target = target
        view.onClick = onClick
        view.onHover = onHover
        view.makeMenu = makeMenu
        view.drag = drag
        view.onMenuVisibility = onMenuVisibility
    }

    final class InteractionNSView: NSView {
        var target: InteractionTarget?
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        var makeMenu: (() -> NSMenu)?
        var drag: DragHandlers?
        var onMenuVisibility: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var pressed = false
        private var pressLocation: NSPoint?
        private var dragging = false
        private static let dragThreshold: CGFloat = 5

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// A group card's layer lies on top of its member-icon layers. Points inside a member
        /// icon are handed to that layer so icons stay clickable and draggable individually.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point), hit === self else { return super.hitTest(point) }
            guard case .item(.group(let group)) = target, let superview, let root = window?.contentView else { return hit }
            let windowPoint = superview.convert(point, to: nil)
            if let member = Self.memberLayer(of: group, containing: windowPoint, under: root) {
                return member
            }
            return hit
        }

        private static func memberLayer(of group: GroupID, containing windowPoint: NSPoint, under root: NSView) -> InteractionNSView? {
            var found: InteractionNSView?
            func walk(_ view: NSView) {
                if found != nil { return }
                if let layer = view as? InteractionNSView, case .member(_, let owner) = layer.target, owner == group,
                   !layer.isHiddenOrHasHiddenAncestor, layer.convert(layer.bounds, to: nil).contains(windowPoint) {
                    found = layer
                    return
                }
                for child in view.subviews { walk(child) }
            }
            walk(root)
            return found
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
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
            dragging = false
            pressLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard pressed, let start = pressLocation else { return }
            let current = event.locationInWindow
            if !dragging {
                guard abs(current.x - start.x) >= Self.dragThreshold || abs(current.y - start.y) >= Self.dragThreshold else { return }
                guard let target, let drag else { return }
                dragging = true
                drag.began(target, current)
            }
            drag?.moved(current)
        }

        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            defer { pressLocation = nil }
            if dragging {
                dragging = false
                drag?.ended(event.locationInWindow, true)
                return
            }
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
            onMenuVisibility?(true)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            onMenuVisibility?(false)
        }
    }
}
