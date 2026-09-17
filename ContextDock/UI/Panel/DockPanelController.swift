import AppKit
import SwiftUI

/// Owns the bar panel: hosting, sizing, screen placement and visibility.
@MainActor
final class DockPanelController {
    private let panel = DockPanel()
    private let store: WindowStore
    private let barState: BarState
    private let preferences: Preferences
    private var isVisible = false

    var onActivate: ((BarItemID) -> Void)?
    var onActivateMember: ((WindowSessionID) -> Void)?
    var onMenu: ((InteractionTarget) -> NSMenu)?
    var onRequestPermission: (() -> Void)?
    let dragCoordinator: DragCoordinator

    init(store: WindowStore, barState: BarState, preferences: Preferences) {
        self.store = store
        self.barState = barState
        self.preferences = preferences
        self.dragCoordinator = DragCoordinator(store: store, barState: barState)

        dragCoordinator.isVertical = { preferences.barEdge.isVertical }
        let root = DockBarView(
            store: store,
            barState: barState,
            preferences: preferences,
            onActivate: { [weak self] id in self?.onActivate?(id) },
            onActivateMember: { [weak self] id in self?.onActivateMember?(id) },
            onMenu: { [weak self] target in self?.onMenu?(target) ?? NSMenu() },
            onRequestPermission: { [weak self] in self?.onRequestPermission?() },
            dragHandlers: dragCoordinator.handlers
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        dragCoordinator.attach(contentView: hosting)
        relayout()
    }

    var window: NSWindow { panel }

    func show() {
        isVisible = true
        relayout()
        panel.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    var isShown: Bool { isVisible }

    /// Recomputes the frame from the current item count, edge, card size, screen and margin.
    func relayout() {
        guard let screen = ScreenPlacement.resolve(preferences.screenSelection) else { return }
        let count = store.permission.isGranted ? store.items.count : 0
        let metrics = preferences.cardMetrics
        let vertical = preferences.barEdge.isVertical
        let frame = ScreenPlacement.barFrame(
            edge: preferences.barEdge,
            preferredLength: DockBarView.preferredLength(itemCount: count, metrics: metrics, vertical: vertical),
            thickness: DockBarView.thickness(metrics: metrics, vertical: vertical),
            margin: CGFloat(preferences.bottomMargin),
            on: screen
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Screen coordinates of an item, used to anchor popovers/panels.
    func anchorRect(for id: BarItemID) -> NSRect {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else { return panel.frame }
        let metrics = preferences.cardMetrics
        if preferences.barEdge.isVertical {
            // First item at the top; AppKit coordinates grow upwards.
            let y = panel.frame.maxY - DockBarView.padding - CGFloat(index + 1) * metrics.height - CGFloat(index) * DockBarView.spacing
            return NSRect(x: panel.frame.minX, y: y, width: panel.frame.width, height: metrics.height)
        }
        let x = panel.frame.minX + DockBarView.padding + CGFloat(index) * (metrics.width + DockBarView.spacing)
        return NSRect(x: x, y: panel.frame.minY, width: metrics.width, height: panel.frame.height)
    }
}
