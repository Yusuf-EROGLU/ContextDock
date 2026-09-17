import AppKit

/// Menu bar item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var isBarVisible: () -> Bool = { true }
    var isBarCollapsed: () -> Bool = { false }
    var onToggleCollapsed: (() -> Void)?
    var permissionState: () -> PermissionState = { .unknown }
    var onToggleBar: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSearch: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPermission: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "ContextDock")
            button.toolTip = "ContextDock"
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: isBarVisible() ? "Hide Bar" : "Show Bar", action: #selector(toggleBar), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        if isBarVisible() {
            let collapse = NSMenuItem(title: isBarCollapsed() ? "Expand Bar" : "Collapse Bar to Handle", action: #selector(toggleCollapsed), keyEquivalent: "")
            collapse.target = self
            menu.addItem(collapse)
        }

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if onSearch != nil {
            let search = NSMenuItem(title: "Search Windows…", action: #selector(search), keyEquivalent: "")
            search.target = self
            menu.addItem(search)
        }

        menu.addItem(.separator())

        let permissionTitle: String
        switch permissionState() {
        case .granted: permissionTitle = "Accessibility: Granted"
        case .denied: permissionTitle = "Accessibility: Not Granted…"
        case .revoked: permissionTitle = "Accessibility: Revoked…"
        case .unknown: permissionTitle = "Accessibility: Checking…"
        }
        let permission = NSMenuItem(title: permissionTitle, action: #selector(showPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ContextDock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleBar() { onToggleBar?() }
    @objc private func toggleCollapsed() { onToggleCollapsed?() }
    @objc private func refresh() { onRefresh?() }
    @objc private func search() { onSearch?() }
    @objc private func showSettings() { onSettings?() }
    @objc private func showPermission() { onPermission?() }
    @objc private func quit() { onQuit?() }
}
