import AppKit
import SwiftUI

/// The small capsule attached to the bar. Shows the number of cards; clicking it collapses or
/// expands the bar, and hovering it for a moment expands a collapsed bar.
struct HandleView: View {
    static let size = CGSize(width: 80, height: 28)
    static let gap: CGFloat = 4
    static let hoverExpandDelay: Duration = .milliseconds(500)

    let count: Int
    let isCollapsed: Bool
    let edge: BarEdge
    var onToggle: () -> Void
    var onHoverExpand: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: chevron)
                .font(.system(size: 10, weight: .bold))
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(count == 1 ? "window" : "windows")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.1)))
        )
        .overlay(HandleInteractionView(
            onClick: onToggle,
            onHover: { inside in hovering = inside },
            onDwell: { if isCollapsed { onHoverExpand() } },
            dwell: Self.hoverExpandDelay
        ))
        .help(isCollapsed ? "Show the bar" : "Collapse the bar")
        .accessibilityLabel(isCollapsed ? "Show ContextDock bar, \(count) windows" : "Collapse ContextDock bar")
        .accessibilityAddTraits(.isButton)
    }

    /// Points towards where the cards appear when expanded.
    private var chevron: String {
        switch (edge, isCollapsed) {
        case (.bottom, true): return "chevron.up"
        case (.bottom, false): return "chevron.down"
        case (.top, true): return "chevron.down"
        case (.top, false): return "chevron.up"
        case (.left, true): return "chevron.right"
        case (.left, false): return "chevron.left"
        case (.right, true): return "chevron.left"
        case (.right, false): return "chevron.right"
        }
    }
}

/// Click, hover and dwell handling for the handle in a non-key panel.
struct HandleInteractionView: NSViewRepresentable {
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var onDwell: () -> Void
    var dwell: Duration

    func makeNSView(context: Context) -> HandleNSView {
        let view = HandleNSView()
        apply(view)
        return view
    }

    func updateNSView(_ nsView: HandleNSView, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: HandleNSView) {
        view.onClick = onClick
        view.onHover = onHover
        view.onDwell = onDwell
        view.dwell = dwell
    }

    final class HandleNSView: NSView {
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        var onDwell: (() -> Void)?
        var dwell: Duration = .milliseconds(500)
        private var trackingArea: NSTrackingArea?
        private var dwellTask: Task<Void, Never>?
        private var pressed = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
            dwellTask?.cancel()
            let delay = dwell
            dwellTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.onDwell?()
            }
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
            dwellTask?.cancel()
            dwellTask = nil
        }

        override func mouseDown(with event: NSEvent) { pressed = true }

        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            dwellTask?.cancel()
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                onClick?()
            }
        }
    }
}
