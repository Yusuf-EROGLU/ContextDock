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

    /// Fraction of a card (along the layout axis) that counts as "stack onto"; the rest of the
    /// card, split in two, means "insert before/after".
    private let stackZone: ClosedRange<CGFloat> = 0.2...0.8

    /// Finds the card under the pointer by geometry rather than AppKit hit-testing, so SwiftUI's
    /// own drawing views and member-icon layers cannot swallow the hit. The leading/trailing
    /// slices of a card (left/right, or top/bottom on a vertical bar) mean "insert before/after";
    /// the middle means "stack onto".
    private func dropTarget(at windowPoint: NSPoint) -> BarState.DropTarget? {
        guard let contentView, let origin else { return nil }
        let local = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.insetBy(dx: -40, dy: -60).contains(local) else {
            return fromGroup != nil ? .detach : nil
        }

        let overlays = interactionViews(in: contentView)
        // Item layers cover whole cards; member layers sit inside group cards and resolve to
        // their group. Prefer an item layer when both contain the point.
        var hovered: BarItemID?
        var frame: NSRect?
        for view in overlays {
            guard let target = view.target, let window = view.window else { continue }
            let rect = view.convert(view.bounds, to: nil)
            guard rect.contains(windowPoint) else { continue }
            switch target {
            case .item(let id):
                hovered = id
                frame = rect
            case .member(_, let group):
                if hovered == nil {
                    hovered = .group(group)
                    frame = itemFrame(for: .group(group), in: overlays) ?? rect
                }
            }
            _ = window
        }
        guard let hovered, let frame else {
            return fromGroup != nil ? .detach : .insert(before: nil)
        }
        if hovered == origin { return nil }
        if case .group(let group) = hovered, fromGroup == group { return nil }

        // Fraction along the layout direction, 0 = leading (left, or top on a vertical bar).
        let fraction: CGFloat
        if isVertical() {
            fraction = (frame.maxY - windowPoint.y) / max(frame.height, 1)
        } else {
            fraction = (windowPoint.x - frame.minX) / max(frame.width, 1)
        }
        if fraction < stackZone.lowerBound {
            return .insert(before: hovered)
        }
        if fraction > stackZone.upperBound {
            return .insert(before: itemAfter(hovered))
        }
        return .stack(hovered)
    }

    private func interactionViews(in root: NSView) -> [CardInteractionView.InteractionNSView] {
        var result: [CardInteractionView.InteractionNSView] = []
        func walk(_ view: NSView) {
            if let interaction = view as? CardInteractionView.InteractionNSView, !interaction.isHiddenOrHasHiddenAncestor {
                result.append(interaction)
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return result
    }

    private func itemFrame(for id: BarItemID, in overlays: [CardInteractionView.InteractionNSView]) -> NSRect? {
        overlays.first { $0.target == .item(id) }.map { $0.convert($0.bounds, to: nil) }
    }

    private func itemAfter(_ id: BarItemID) -> BarItemID? {
        let ids = store.items.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        let next = index + 1
        return next < ids.count ? ids[next] : nil
    }
}
