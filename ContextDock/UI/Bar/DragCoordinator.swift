import AppKit

/// Tracks a card drag inside the bar: hit-tests the interaction overlays under the pointer to
/// find the drop target, drives the visual drag state, and applies the drop to the store.
@MainActor
final class DragCoordinator {
    private let store: WindowStore
    private let barState: BarState
    /// Supplies the current layout axis (top/bottom bars are horizontal, left/right vertical).
    var isVertical: () -> Bool = { false }
    private weak var contentView: NSView?
    private var origin: BarItemID?
    private var fromGroup: GroupID?

    init(store: WindowStore, barState: BarState) {
        self.store = store
        self.barState = barState
    }

    func attach(contentView: NSView) {
        self.contentView = contentView
    }

    var handlers: DragHandlers {
        DragHandlers(
            began: { [weak self] target, point in self?.began(target, at: point) },
            moved: { [weak self] point in self?.moved(to: point) },
            ended: { [weak self] point, commit in self?.ended(at: point, commit: commit) }
        )
    }

    private func began(_ target: InteractionTarget, at point: NSPoint) {
        let item = target.draggedItem
        origin = item
        if case .member(let window, let group) = target {
            fromGroup = group
            _ = window
        } else {
            fromGroup = nil
        }
        barState.hoveredItem = nil
        barState.drag = BarState.DragState(item: item, location: convert(point), target: nil, fromGroup: fromGroup)
    }

    private func moved(to point: NSPoint) {
        guard var drag = barState.drag else { return }
        drag.location = convert(point)
        drag.target = dropTarget(at: point)
        barState.drag = drag
    }

    private func ended(at point: NSPoint, commit: Bool) {
        defer {
            barState.drag = nil
            origin = nil
            fromGroup = nil
        }
        guard commit, let origin, let target = dropTarget(at: point) else { return }
        switch target {
        case .stack(let onto):
            store.stack(origin, onto: onto)
        case .insert(let before):
            store.move(origin, before: before)
        case .detach:
            if case .window(let window) = origin { store.removeFromGroup(window) }
        }
    }

    /// Converts a window-coordinate point to the bar view's top-left coordinate space.
    /// `NSHostingView` is already flipped (y grows downwards), so no manual flip in that case.
    private func convert(_ point: NSPoint) -> CGPoint {
        guard let contentView else { return CGPoint(x: point.x, y: point.y) }
        let local = contentView.convert(point, from: nil)
        let y = contentView.isFlipped ? local.y : contentView.bounds.height - local.y
        return CGPoint(x: local.x, y: y)
    }

    /// Finds the interaction overlay under the pointer. The leading/trailing thirds of a card
    /// (left/right, or top/bottom on a vertical bar) mean "insert before/after"; the middle
    /// third means "stack onto".
    private func dropTarget(at windowPoint: NSPoint) -> BarState.DropTarget? {
        guard let contentView, let origin else { return nil }
        let local = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.insetBy(dx: -40, dy: -60).contains(local) else {
            return fromGroup != nil ? .detach : nil
        }
        var view = contentView.hitTest(local)
        while let current = view, !(current is CardInteractionView.InteractionNSView) {
            view = current.superview
        }
        guard let overlay = view as? CardInteractionView.InteractionNSView, let target = overlay.target else {
            return fromGroup != nil ? .detach : .insert(before: nil)
        }
        let hovered: BarItemID
        switch target {
        case .item(let id): hovered = id
        case .member(_, let group): hovered = .group(group)
        }
        if hovered == origin { return nil }
        if case .group(let group) = hovered, fromGroup == group { return nil }

        let point = overlay.convert(windowPoint, from: nil)
        // Fraction along the layout direction, 0 = leading (left, or top on a vertical bar).
        let fraction: CGFloat
        if isVertical() {
            // AppKit y grows upwards; the first card is at the top.
            fraction = overlay.isFlipped ? point.y / overlay.bounds.height : 1 - point.y / overlay.bounds.height
        } else {
            fraction = point.x / overlay.bounds.width
        }
        if fraction < 0.3 {
            return .insert(before: hovered)
        }
        if fraction > 0.7 {
            return .insert(before: itemAfter(hovered))
        }
        return .stack(hovered)
    }

    private func itemAfter(_ id: BarItemID) -> BarItemID? {
        let ids = store.items.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        let next = index + 1
        return next < ids.count ? ids[next] : nil
    }
}
