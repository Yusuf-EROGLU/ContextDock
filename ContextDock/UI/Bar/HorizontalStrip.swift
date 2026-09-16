import AppKit
import SwiftUI

/// AppKit-backed horizontal strip for the cards. Unlike SwiftUI's `ScrollView`, it turns
/// vertical wheel/trackpad scrolling into horizontal movement, shows an overlay scroller, and
/// offers edge arrow buttons whenever the content is wider than the visible area.
struct HorizontalStrip<Content: View>: NSViewRepresentable {
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> StripView<Content> {
        let view = StripView(rootView: content(), height: height)
        return view
    }

    func updateNSView(_ nsView: StripView<Content>, context: Context) {
        nsView.update(rootView: content())
    }

    final class StripView<Root: View>: NSView {
        private let scrollView = WheelRedirectingScrollView()
        private let hosting: NSHostingView<Root>
        private let leftButton = NSButton()
        private let rightButton = NSButton()
        private let height: CGFloat

        init(rootView: Root, height: CGFloat) {
            self.height = height
            hosting = NSHostingView(rootView: rootView)
            super.init(frame: .zero)

            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.translatesAutoresizingMaskIntoConstraints = true

            scrollView.documentView = hosting
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.verticalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            addSubview(scrollView)

            configure(leftButton, symbol: "chevron.left", action: #selector(scrollLeft))
            configure(rightButton, symbol: "chevron.right", action: #selector(scrollRight))

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                leftButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                leftButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                rightButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                rightButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

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
            updateButtons()
        }

        private func configure(_ button: NSButton, symbol: String, action: Selector) {
            button.bezelStyle = .circular
            button.isBordered = true
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.left" ? "Scroll left" : "Scroll right")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isHidden = true
            button.alphaValue = 0.9
            addSubview(button)
        }

        @objc private func boundsChanged() {
            updateButtons()
        }

        private func updateButtons() {
            let visible = scrollView.contentView.bounds
            let total = hosting.frame.width
            let overflow = total > visible.width + 1
            leftButton.isHidden = !overflow || visible.minX <= 1
            rightButton.isHidden = !overflow || visible.maxX >= total - 1
        }

        @objc private func scrollLeft() { scroll(by: -pageWidth) }
        @objc private func scrollRight() { scroll(by: pageWidth) }

        private var pageWidth: CGFloat { max(scrollView.contentView.bounds.width * 0.8, 100) }

        private func scroll(by delta: CGFloat) {
            let clip = scrollView.contentView
            let maxX = max(0, hosting.frame.width - clip.bounds.width)
            let target = min(max(0, clip.bounds.minX + delta), maxX)
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 20))
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                self.updateButtons()
            }
        }
    }
}

/// Scroll view that maps predominantly vertical wheel input to horizontal scrolling, so a
/// plain mouse wheel moves the strip without holding Shift.
final class WheelRedirectingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), event.phase == [] || event.phase == .changed || event.momentumPhase != [] else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        guard let document = documentView else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let target = min(max(0, clip.bounds.minX - step), maxX)
        clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }
}
