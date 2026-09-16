import AppKit
import SwiftUI

/// AppKit-backed horizontal strip for the cards. Unlike SwiftUI's `ScrollView`, it turns
/// vertical wheel/trackpad scrolling into horizontal movement and supports click-and-drag
/// panning (see `StripPanning`). No scroller is drawn, so nothing overlaps the cards.
struct HorizontalStrip<Content: View>: NSViewRepresentable {
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> StripView<Content> {
        StripView(rootView: content(), height: height)
    }

    func updateNSView(_ nsView: StripView<Content>, context: Context) {
        nsView.update(rootView: content())
    }

    final class StripView<Root: View>: NSView {
        private let scrollView = WheelRedirectingScrollView()
        private let hosting: NSHostingView<Root>
        private let height: CGFloat
        private var panStart: NSPoint?

        init(rootView: Root, height: CGFloat) {
            self.height = height
            hosting = NSHostingView(rootView: rootView)
            super.init(frame: .zero)

            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.translatesAutoresizingMaskIntoConstraints = true

            scrollView.documentView = hosting
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.verticalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.translatesAutoresizingMaskIntoConstraints = false
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
            NSSize(width: NSView.noIntrinsicMetric, height: height)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func update(rootView: Root) {
            hosting.rootView = rootView
            layoutDocument()
        }

        override func layout() {
            super.layout()
            layoutDocument()
        }

        private func layoutDocument() {
            let fitting = hosting.fittingSize
            let width = max(fitting.width, scrollView.contentView.bounds.width)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            StripPanning.clamp(scrollView)
        }

        // Drag-to-pan on empty strip areas (cards handle their own drags and forward them).
        override func mouseDown(with event: NSEvent) { panStart = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let start = panStart else { return }
            StripPanning.pan(scrollView, by: event.locationInWindow.x - start.x)
            panStart = event.locationInWindow
        }
        override func mouseUp(with event: NSEvent) { panStart = nil }
    }
}

/// Shared helpers for panning an `NSScrollView` horizontally.
@MainActor
enum StripPanning {
    /// Moves the visible area opposite to the pointer movement (grab-and-drag).
    static func pan(_ scrollView: NSScrollView, by deltaX: CGFloat) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return }
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let target = min(max(0, clip.bounds.minX - deltaX), maxX)
        clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    static func clamp(_ scrollView: NSScrollView) {
        pan(scrollView, by: 0)
    }
}

/// Scroll view that maps predominantly vertical wheel input to horizontal scrolling, so a
/// plain mouse wheel moves the strip without holding Shift.
final class WheelRedirectingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        StripPanning.pan(self, by: -step)
    }
}
