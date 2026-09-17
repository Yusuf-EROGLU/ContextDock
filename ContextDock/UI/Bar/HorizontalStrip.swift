import AppKit
import SwiftUI

/// AppKit-backed scrolling strip for the cards, horizontal or vertical. Unlike SwiftUI's
/// `ScrollView`, a horizontal strip turns vertical wheel/trackpad input into horizontal
/// movement, and both orientations support click-and-drag panning on empty areas.
/// No scroller is drawn, so nothing overlaps the cards.
struct CardStrip<Content: View>: NSViewRepresentable {
    let axis: Axis
    /// Size across the scrolling direction (height for horizontal, width for vertical).
    let thickness: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> StripView<Content> {
        StripView(rootView: content(), axis: axis, thickness: thickness)
    }

    func updateNSView(_ nsView: StripView<Content>, context: Context) {
        nsView.update(rootView: content(), axis: axis, thickness: thickness)
    }

    /// Hosting view that asks its superview to lay out again when SwiftUI reports a new ideal
    /// size, so the strip never has to force a measurement itself.
    final class DocumentHostingView<Root: View>: NSHostingView<Root> {
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            enclosingScrollView?.superview?.needsLayout = true
        }
    }

    final class StripView<Root: View>: NSView {
        private let scrollView = WheelRedirectingScrollView()
        private let hosting: DocumentHostingView<Root>
        private var axis: Axis
        private var thickness: CGFloat
        private var panStart: NSPoint?

        init(rootView: Root, axis: Axis, thickness: CGFloat) {
            self.axis = axis
            self.thickness = thickness
            hosting = DocumentHostingView(rootView: rootView)
            super.init(frame: .zero)

            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.translatesAutoresizingMaskIntoConstraints = true

            scrollView.axis = axis
            scrollView.documentView = hosting
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            applyElasticity()
            addSubview(scrollView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        override var intrinsicContentSize: NSSize {
            axis == .horizontal
                ? NSSize(width: NSView.noIntrinsicMetric, height: thickness)
                : NSSize(width: thickness, height: NSView.noIntrinsicMetric)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func update(rootView: Root, axis: Axis, thickness: CGFloat) {
            hosting.rootView = rootView
            if self.axis != axis || self.thickness != thickness {
                self.axis = axis
                self.thickness = thickness
                scrollView.axis = axis
                applyElasticity()
                invalidateIntrinsicContentSize()
            }
            needsLayout = true
        }

        private func applyElasticity() {
            scrollView.horizontalScrollElasticity = axis == .horizontal ? .allowed : .none
            scrollView.verticalScrollElasticity = axis == .vertical ? .allowed : .none
        }

        override func layout() {
            super.layout()
            layoutDocument()
        }

        /// Idempotent: reads SwiftUI's cached intrinsic size (never forces a measurement) and
        /// touches the document frame and scroll position only when they actually change.
        private func layoutDocument() {
            let visible = scrollView.contentView.bounds.size
            let intrinsic = hosting.intrinsicContentSize
            let target: NSRect
            if axis == .horizontal {
                let content = intrinsic.width > 0 && intrinsic.width != NSView.noIntrinsicMetric ? intrinsic.width : 0
                target = NSRect(x: 0, y: 0, width: max(content, visible.width), height: thickness)
            } else {
                let content = intrinsic.height > 0 && intrinsic.height != NSView.noIntrinsicMetric ? intrinsic.height : 0
                target = NSRect(x: 0, y: 0, width: thickness, height: max(content, visible.height))
            }
            if hosting.frame != target {
                hosting.frame = target
            }
            StripPanning.clampIfNeeded(scrollView, axis: axis)
        }

        override func mouseDown(with event: NSEvent) { panStart = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let start = panStart else { return }
            let delta = axis == .horizontal ? event.locationInWindow.x - start.x : event.locationInWindow.y - start.y
            StripPanning.pan(scrollView, axis: axis, by: delta)
            panStart = event.locationInWindow
        }
        override func mouseUp(with event: NSEvent) { panStart = nil }
    }
}

/// Shared helpers for panning an `NSScrollView` along one axis.
@MainActor
enum StripPanning {
    /// Moves the visible area opposite to the pointer movement (grab-and-drag). `delta` is in
    /// window coordinates along the axis (AppKit y grows upwards).
    static func pan(_ scrollView: NSScrollView, axis: Axis, by delta: CGFloat) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return }
        var origin = clip.bounds.origin
        if axis == .horizontal {
            let maxX = max(0, document.frame.width - clip.bounds.width)
            origin.x = min(max(0, origin.x - delta), maxX)
        } else {
            let maxY = max(0, document.frame.height - clip.bounds.height)
            origin.y = min(max(0, origin.y - delta), maxY)
        }
        if origin != clip.bounds.origin {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    static func clampIfNeeded(_ scrollView: NSScrollView, axis: Axis) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return }
        if axis == .horizontal {
            let maxX = max(0, document.frame.width - clip.bounds.width)
            if clip.bounds.minX > maxX || clip.bounds.minX < 0 { pan(scrollView, axis: axis, by: 0) }
        } else {
            let maxY = max(0, document.frame.height - clip.bounds.height)
            if clip.bounds.minY > maxY || clip.bounds.minY < 0 { pan(scrollView, axis: axis, by: 0) }
        }
    }
}

/// Scroll view that, in horizontal mode, maps predominantly vertical wheel input to horizontal
/// scrolling so a plain mouse wheel moves the strip without holding Shift.
final class WheelRedirectingScrollView: NSScrollView {
    var axis: Axis = .horizontal

    override func scrollWheel(with event: NSEvent) {
        guard axis == .horizontal, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        StripPanning.pan(self, axis: .horizontal, by: -step)
    }
}
