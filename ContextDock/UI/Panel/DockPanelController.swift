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

    var onActivate: ((WindowSessionID) -> Void)?
    var onMenu: ((WindowSessionID) -> NSMenu)?
    var onRequestPermission: (() -> Void)?

    init(store: WindowStore, barState: BarState, preferences: Preferences) {
        self.store = store
        self.barState = barState
        self.preferences = preferences

        let root = DockBarView(
            store: store,
            barState: barState,
            onActivate: { [weak self] id in self?.onActivate?(id) },
            onMenu: { [weak self] id in self?.onMenu?(id) ?? NSMenu() },
            onRequestPermission: { [weak self] in self?.onRequestPermission?() }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
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

    /// Recomputes the frame from the current card count, screen and preferences.
    func relayout() {
        guard let screen = ScreenPlacement.resolve(preferences.screenSelection) else { return }
        let count = store.permission.isGranted ? store.cards.count : 0
        let frame = ScreenPlacement.barFrame(
            preferredWidth: DockBarView.preferredWidth(cardCount: count),
            height: DockBarView.preferredHeight,
            bottomMargin: CGFloat(preferences.bottomMargin),
            on: screen
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Screen coordinates of a card, used to anchor popovers/panels.
    func anchorRect(for id: WindowSessionID) -> NSRect {
        guard let index = store.cards.firstIndex(where: { $0.id == id }) else { return panel.frame }
        let x = panel.frame.minX + DockBarView.padding + CGFloat(index) * (WindowCardView.width + DockBarView.spacing)
        return NSRect(x: x, y: panel.frame.minY, width: WindowCardView.width, height: panel.frame.height)
    }
}
