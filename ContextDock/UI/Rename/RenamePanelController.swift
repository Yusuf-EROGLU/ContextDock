import AppKit
import SwiftUI

struct RenameView: View {
    let heading: String
    let hint: String
    @State var name: String
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)
                .lineLimit(1)
            TextField("Custom name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSave(name) }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") { onSave("") }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}

/// Presents small key-capable panels (rename, badge picker, details) next to a card.
@MainActor
final class PopupPanelPresenter {
    private var panel: KeyablePanel?

    func present<Content: View>(_ content: Content, near anchor: NSRect, preferredSize: NSSize) {
        dismiss()
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: preferredSize))
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize == .zero ? preferredSize : hosting.fittingSize)

        var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.maxY + 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            if origin.y + panel.frame.height > visible.maxY {
                origin.y = anchor.minY - panel.frame.height - 10
            }
        }
        panel.setFrameOrigin(origin)
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isPresented: Bool { panel != nil }
}
