import AppKit
import SwiftUI

/// Builds the card context menu and runs its actions (rename, badge, details, reset,
/// project folder binding).
@MainActor
final class CardActions: NSObject {
    private let store: WindowStore
    private let barState: BarState
    private let popup: PopupPanelPresenter
    private var pendingAnchor: NSRect = .zero
    private(set) var editingCard: WindowSessionID?

    /// Installed in M2 by the project binding coordinator.
    var onAttachProject: ((WindowSessionID) -> Void)?

    init(store: WindowStore, barState: BarState, popup: PopupPanelPresenter) {
        self.store = store
        self.barState = barState
        self.popup = popup
    }

    func menu(for id: WindowSessionID, anchor: NSRect) -> NSMenu {
        pendingAnchor = anchor
        let menu = NSMenu()
        guard let card = store.card(for: id) else {
            menu.addItem(withTitle: "Window closed", action: nil, keyEquivalent: "")
            return menu
        }
        let representedID = id.rawValue.uuidString

        func item(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = representedID
            item.isEnabled = enabled
            return item
        }

        menu.autoenablesItems = false
        menu.addItem(item("Rename…", #selector(rename(_:))))
        menu.addItem(item("Badge & Color…", #selector(badge(_:))))
        menu.addItem(item("Attach Project Folder…", #selector(attachProject(_:)), enabled: onAttachProject != nil))
        if card.context.contextSource == .manual {
            menu.addItem(item("Detach Project Folder", #selector(detachProject(_:))))
        }
        menu.addItem(.separator())
        let hasCustomization = store.customizations[id] != nil
        menu.addItem(item("Reset Customization", #selector(reset(_:)), enabled: hasCustomization))
        menu.addItem(item("Details…", #selector(details(_:))))
        return menu
    }

    private func cardID(from sender: Any?) -> WindowSessionID? {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let uuid = UUID(uuidString: raw) else { return nil }
        return WindowSessionID(rawValue: uuid)
    }

    private func projectWindowCount(for card: CardViewModel) -> Int {
        guard let path = card.context.projectPath else { return 0 }
        return store.cards.filter { $0.context.hasTrustedProjectPath && $0.context.projectPath == path && $0.applicationKind == card.applicationKind }.count
    }

    @objc private func rename(_ sender: Any?) {
        guard let id = cardID(from: sender), let card = store.card(for: id) else { return }
        editingCard = id
        let canRemember = card.context.hasTrustedProjectPath
        let view = RenameView(
            card: card,
            canRememberForProject: canRemember,
            projectWindowCount: projectWindowCount(for: card),
            name: store.customizations[id]?.name ?? "",
            onSave: { [weak self] name, scope in
                guard let self else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                switch scope {
                case .window:
                    store.rename(id, to: trimmed.isEmpty ? nil : trimmed)
                case .project:
                    if let path = card.context.projectPath {
                        store.upsertRule(kind: card.applicationKind, projectPath: path) { rule in
                            rule.customLabel = trimmed.isEmpty ? nil : trimmed
                        }
                        store.rename(id, to: nil)
                    }
                }
                self.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 340, height: 200))
    }

    @objc private func badge(_ sender: Any?) {
        guard let id = cardID(from: sender), let card = store.card(for: id) else { return }
        editingCard = id
        let view = BadgePickerView(
            card: card,
            canRememberForProject: card.context.hasTrustedProjectPath,
            badge: card.badge,
            color: card.colorToken,
            onApply: { [weak self] badge, color, scope in
                guard let self else { return }
                switch scope {
                case .window:
                    store.setBadge(id, badge: badge, color: color)
                case .project:
                    if let path = card.context.projectPath {
                        store.upsertRule(kind: card.applicationKind, projectPath: path) { rule in
                            rule.badge = badge
                            rule.colorToken = color == ColorToken.none ? nil : color
                        }
                        store.setBadge(id, badge: nil, color: ColorToken.none)
                    }
                }
                self.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 320, height: 380))
    }

    @objc private func attachProject(_ sender: Any?) {
        guard let id = cardID(from: sender) else { return }
        onAttachProject?(id)
    }

    @objc private func detachProject(_ sender: Any?) {
        guard let id = cardID(from: sender) else { return }
        store.bindProject(id, binding: nil)
    }

    @objc private func reset(_ sender: Any?) {
        guard let id = cardID(from: sender) else { return }
        store.resetCustomization(id)
    }

    @objc private func details(_ sender: Any?) {
        guard let id = cardID(from: sender), let card = store.card(for: id) else { return }
        editingCard = id
        let view = WindowDetailsView(
            card: card,
            window: store.windowSnapshot(for: id),
            customization: store.customizations[id],
            onClose: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 460, height: 400))
    }

    private func finishEditing() {
        editingCard = nil
        popup.dismiss()
    }
}
