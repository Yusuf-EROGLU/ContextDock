import AppKit
import SwiftUI

/// Builds context menus for window cards, group cards and group members, and runs their
/// actions (rename, badge, details, grouping).
@MainActor
final class CardActions: NSObject {
    private let store: WindowStore
    private let barState: BarState
    private let popup: PopupPanelPresenter
    private var pendingAnchor: NSRect = .zero
    private(set) var editingItem: BarItemID?

    var onActivateWindow: ((WindowSessionID) -> Void)?
    var onActivateGroup: ((GroupID) -> Void)?

    init(store: WindowStore, barState: BarState, popup: PopupPanelPresenter) {
        self.store = store
        self.barState = barState
        self.popup = popup
    }

    func menu(for target: InteractionTarget, anchor: NSRect) -> NSMenu {
        pendingAnchor = anchor
        switch target {
        case .item(.window(let id)):
            return windowMenu(id, inGroup: store.group(containing: id)?.id)
        case .item(.group(let id)):
            return groupMenu(id)
        case .member(let window, let group):
            return windowMenu(window, inGroup: group)
        }
    }

    private func item(_ title: String, _ selector: Selector, represented: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.isEnabled = enabled
        return item
    }

    private func windowMenu(_ id: WindowSessionID, inGroup group: GroupID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard store.card(for: id) != nil else {
            menu.addItem(withTitle: "Window closed", action: nil, keyEquivalent: "")
            return menu
        }
        let rep = id.rawValue.uuidString
        if group != nil {
            menu.addItem(item("Switch to This Window", #selector(activateWindow(_:)), represented: rep))
            menu.addItem(.separator())
        }
        menu.addItem(item("Rename…", #selector(renameWindow(_:)), represented: rep))
        menu.addItem(item("Badge & Color…", #selector(badgeWindow(_:)), represented: rep))
        menu.addItem(.separator())
        if group != nil {
            menu.addItem(item("Remove from Group", #selector(removeFromGroup(_:)), represented: rep))
        } else {
            let addTo = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for group in store.arrangement.groupList {
                let title = store.groupViewModel(group.id)?.title ?? "Group"
                submenu.addItem(item(title, #selector(addToGroup(_:)), represented: "\(rep)|\(group.id.rawValue.uuidString)"))
            }
            addTo.submenu = submenu
            addTo.isEnabled = !submenu.items.isEmpty
            menu.addItem(addTo)
        }
        menu.addItem(.separator())
        menu.addItem(item("Reset Customization", #selector(resetWindow(_:)), represented: rep, enabled: store.customizations[id] != nil))
        menu.addItem(item("Details…", #selector(details(_:)), represented: rep))
        return menu
    }

    private func groupMenu(_ id: GroupID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let group = store.groupViewModel(id) else { return menu }
        let rep = id.rawValue.uuidString
        menu.addItem(item("Open All Windows", #selector(activateGroup(_:)), represented: rep))
        menu.addItem(.separator())
        for member in group.members {
            let entry = item("\(member.applicationName): \(member.title)", #selector(activateWindow(_:)), represented: member.id.rawValue.uuidString)
            entry.image = store.icon(for: member).map { image in
                let copy = image.copy() as! NSImage
                copy.size = NSSize(width: 16, height: 16)
                return copy
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Rename Group…", #selector(renameGroup(_:)), represented: rep))
        menu.addItem(item("Badge & Color…", #selector(badgeGroup(_:)), represented: rep))
        menu.addItem(item("Ungroup", #selector(ungroup(_:)), represented: rep))
        return menu
    }

    private func windowID(_ sender: Any?) -> WindowSessionID? {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let uuid = UUID(uuidString: raw.split(separator: "|").first.map(String.init) ?? raw) else { return nil }
        return WindowSessionID(rawValue: uuid)
    }

    private func groupID(_ sender: Any?) -> GroupID? {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let uuid = UUID(uuidString: raw.split(separator: "|").last.map(String.init) ?? raw) else { return nil }
        return GroupID(rawValue: uuid)
    }

    // MARK: - Window actions

    @objc private func activateWindow(_ sender: Any?) {
        guard let id = windowID(sender) else { return }
        onActivateWindow?(id)
    }

    @objc private func renameWindow(_ sender: Any?) {
        guard let id = windowID(sender), let card = store.card(for: id) else { return }
        editingItem = .window(id)
        let view = RenameView(
            heading: "Rename “\(card.rawTitle ?? card.applicationName)”",
            hint: "Remembered across launches and re-attached to this window by app and title. Cleared with Reset Customization or when the window is closed.",
            name: store.customizations[id]?.name ?? "",
            onSave: { [weak self] name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.store.rename(id, to: trimmed.isEmpty ? nil : trimmed)
                self?.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 340, height: 160))
    }

    @objc private func badgeWindow(_ sender: Any?) {
        guard let id = windowID(sender), let card = store.card(for: id) else { return }
        editingItem = .window(id)
        let view = BadgePickerView(
            heading: "Badge & Color for “\(card.title)”",
            badge: card.badge,
            color: card.colorToken,
            onApply: { [weak self] badge, color in
                self?.store.setBadge(id, badge: badge, color: color)
                self?.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 320, height: 380))
    }

    @objc private func removeFromGroup(_ sender: Any?) {
        guard let id = windowID(sender) else { return }
        store.removeFromGroup(id)
    }

    @objc private func addToGroup(_ sender: Any?) {
        guard let window = windowID(sender), let group = groupID(sender) else { return }
        store.stack(.window(window), onto: .group(group))
    }

    @objc private func resetWindow(_ sender: Any?) {
        guard let id = windowID(sender) else { return }
        store.resetCustomization(id)
    }

    @objc private func details(_ sender: Any?) {
        guard let id = windowID(sender), let card = store.card(for: id) else { return }
        editingItem = .window(id)
        let view = WindowDetailsView(
            card: card,
            window: store.windowSnapshot(for: id),
            customization: store.customizations[id],
            group: store.group(containing: id),
            onClose: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 460, height: 400))
    }

    // MARK: - Group actions

    @objc private func activateGroup(_ sender: Any?) {
        guard let id = groupID(sender) else { return }
        onActivateGroup?(id)
    }

    @objc private func renameGroup(_ sender: Any?) {
        guard let id = groupID(sender), let group = store.groupViewModel(id) else { return }
        editingItem = .group(id)
        let view = RenameView(
            heading: "Rename group “\(group.title)”",
            hint: "Remembered across launches. The group breaks only when you ungroup it or one of its windows is closed while ContextDock is running.",
            name: store.group(id)?.name ?? "",
            onSave: { [weak self] name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.store.renameGroup(id, to: trimmed.isEmpty ? nil : trimmed)
                self?.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 340, height: 160))
    }

    @objc private func badgeGroup(_ sender: Any?) {
        guard let id = groupID(sender), let group = store.groupViewModel(id) else { return }
        editingItem = .group(id)
        let view = BadgePickerView(
            heading: "Badge & Color for group “\(group.title)”",
            badge: group.badge,
            color: group.colorToken,
            onApply: { [weak self] badge, color in
                self?.store.setGroupBadge(id, badge: badge, color: color)
                self?.finishEditing()
            },
            onCancel: { [weak self] in self?.finishEditing() }
        )
        popup.present(view, near: pendingAnchor, preferredSize: NSSize(width: 320, height: 380))
    }

    @objc private func ungroup(_ sender: Any?) {
        guard let id = groupID(sender) else { return }
        store.ungroup(id)
    }

    private func finishEditing() {
        editingItem = nil
        popup.dismiss()
    }
}
