import AppKit
import SwiftUI

/// Composition root: creates the services, the UI controllers and wires them together.
@MainActor
final class AppServices {
    let preferences = Preferences()
    let apps = RunningAppsProvider()
    let persistence = PersistenceService()
    let customizations = SessionCustomizationStore()
    let barState = BarState()
    let store: WindowStore
    let worker: AXWorker
    let focus: FocusService

    private(set) lazy var panelController = DockPanelController(store: store, barState: barState, preferences: preferences)
    private(set) lazy var permissionWindow = PermissionWindowController(store: store)
    private(set) lazy var settingsWindow = SettingsWindowController { [unowned self] in self.makeSettingsView() }
    private let statusItem = StatusItemController()
    private let popup = PopupPanelPresenter()
    let cardActions: CardActions

    private(set) lazy var search = SearchPanelController(store: store, preferences: preferences)
    private let hotkeyRegistrar = CarbonHotkeyRegistrar()
    private(set) lazy var hotkeyModel = HotkeyModel(registrar: hotkeyRegistrar, persistence: persistence)
    private(set) lazy var unityBridge = UnityBridgeMonitor(store: store)
    private(set) lazy var autoHide = AutoHideController(preferences: preferences, barState: barState, panel: panelController.window)
    private(set) lazy var memory = SessionMemory(store: store, persistence: persistence)

    private var snapshotTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var didShowPermissionOnboarding = false
    private var activationCounter: UInt64 = 0

    init() {
        store = WindowStore(customizations: customizations, persistence: persistence, apps: apps)
        let apps = self.apps
        let control = MainActorAppControl(
            runningApps: { apps.descriptors() },
            activate: { pid in apps.activate(pid: pid) },
            unhide: { pid in apps.unhide(pid: pid) }
        )
        worker = AXWorker(control: control)
        focus = FocusService(port: worker)
        cardActions = CardActions(store: store, barState: barState, popup: popup)
    }

    // MARK: - Lifecycle

    func start() {
        wireStatusItem()
        wirePanel()
        wireStoreCallbacks()
        observeWorkspace()
        observePreferences()

        let worker = self.worker
        let store = self.store
        snapshotTask = Task { @MainActor [weak self] in
            for await snapshot in worker.snapshots {
                store.apply(snapshot)
                self?.memory.sync()
                self?.handlePermissionChange(snapshot.permission)
                self?.clearStaleHover()
            }
        }
        let showAux = preferences.showAuxiliaryWindows
        Task { @AXActor in
            worker.setShowAuxiliaryWindows(showAux)
            worker.start()
        }

        if preferences.barVisible {
            panelController.show()
        }
        unityBridge.start()
        autoHide.start()
        hotkeyModel.registerSaved()
        Log.app.info("ContextDock started")
        DiagnosticLog.write("app", "started, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    }

    func shutdown() {
        DiagnosticLog.write("app", "terminating")
        snapshotTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        persistence.flush()
        let worker = self.worker
        Task { @AXActor in worker.stop() }
    }

    // MARK: - Wiring

    private func wireStatusItem() {
        statusItem.isBarVisible = { [unowned self] in panelController.isShown }
        statusItem.permissionState = { [unowned self] in store.permission }
        statusItem.onToggleBar = { [unowned self] in preferences.barVisible.toggle() }
        statusItem.isBarCollapsed = { [unowned self] in barState.isCollapsed }
        statusItem.onToggleCollapsed = { [unowned self] in setCollapsed(!barState.isCollapsed) }
        statusItem.onRefresh = { [unowned self] in refresh() }
        statusItem.onSearch = { [unowned self] in search.toggle() }
        statusItem.onSettings = { [unowned self] in settingsWindow.show() }
        statusItem.onPermission = { [unowned self] in permissionWindow.show() }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    private func wirePanel() {
        panelController.onActivate = { [unowned self] item in activate(item) }
        panelController.onActivateMember = { [unowned self] id in activate(.window(id)) }
        panelController.onMenu = { [unowned self] target in
            let anchorItem: BarItemID
            switch target {
            case .item(let id): anchorItem = id
            case .member(_, let group): anchorItem = .group(group)
            }
            return cardActions.menu(for: target, anchor: panelController.anchorRect(for: anchorItem))
        }
        panelController.onRequestPermission = { [unowned self] in
            AXPermission.requestTrust()
            permissionWindow.show()
        }
        permissionWindow.onRecheck = { [unowned self] in refresh() }
        panelController.onToggleCollapsed = { [unowned self] in setCollapsed(!barState.isCollapsed) }
        panelController.onExpand = { [unowned self] in setCollapsed(false) }
        autoHide.isBlocked = { [unowned self] in popup.isPresented || search.isShown }
        autoHide.onCollapse = { [unowned self] in setCollapsed(true) }
        cardActions.onActivateWindow = { [unowned self] id in activate(.window(id)) }
        cardActions.onActivateGroup = { [unowned self] id in activate(.group(id)) }
        search.onChoose = { [unowned self] item in activate(item) }
        hotkeyRegistrar.onPressed = { [unowned self] in search.toggle() }
    }

    private func wireStoreCallbacks() {
        store.onItemsChanged = { [unowned self] in
            panelController.relayout()
            memory.sync()
        }
        store.onWindowsRemoved = { [unowned self] removed in
            let removedItems = Set(removed.map { BarItemID.window($0) })
            if let selected = barState.keyboardSelectedItem, removedItems.contains(selected) {
                barState.keyboardSelectedItem = nil
            }
            if let hovered = barState.hoveredItem, removedItems.contains(hovered) {
                barState.hoveredItem = nil
            }
            if let drag = barState.drag, removedItems.contains(drag.item) {
                barState.drag = nil
            }
            if let editing = cardActions.editingItem, removedItems.contains(editing) {
                popup.dismiss()
                barState.showToast("Window closed")
            }
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let worker = self.worker
        let reconcile: @Sendable (Notification) -> Void = { _ in
            Task { @AXActor in worker.requestReconcile() }
        }
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: reconcile))
        }
        // Logout/shutdown closes every app; those windows are not "closed by the user".
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.memory.freeze() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "system will sleep")
            Task { @MainActor in self?.suspendDiscovery() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "system did wake")
            Task { @MainActor in self?.resumeDiscovery() }
        })
        // Display sleep and the lock screen make macOS report no windows for any app; pausing
        // discovery keeps cards, names and groups intact until the screen is back.
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "screens did sleep")
            Task { @MainActor in self?.suspendDiscovery() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "screens did wake")
            Task { @MainActor in self?.resumeDiscovery() }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "screen locked")
            Task { @MainActor in self?.suspendDiscovery() }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "screen unlocked")
            Task { @MainActor in self?.resumeDiscovery() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "session resigned active")
            Task { @MainActor in self?.suspendDiscovery() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.write("app", "session became active")
            Task { @MainActor in self?.resumeDiscovery() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelController.relayout() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @AXActor in worker.requestReconcile(after: .zero) }
        })
    }

    private func observePreferences() {
        ObservationLoop.observe { [unowned self] in
            let visible = preferences.barVisible
            if visible != panelController.isShown {
                visible ? panelController.show() : panelController.hide()
            }
            applyWorkerMode()
        }
        ObservationLoop.observe { [unowned self] in
            _ = preferences.bottomMargin
            _ = preferences.screenSelection
            _ = preferences.barEdge
            _ = preferences.cardWidth
            _ = preferences.cardHeight
            panelController.relayout()
        }
        ObservationLoop.observe { [unowned self] in
            let show = preferences.showAuxiliaryWindows
            let worker = self.worker
            Task { @AXActor in worker.setShowAuxiliaryWindows(show) }
        }
    }

    /// Stops scanning and freezes the memory's grace clock (sleep, display sleep, lock screen).
    private func suspendDiscovery() {
        let worker = self.worker
        Task { @AXActor in worker.setMode(.paused) }
        memory.suspend()
    }

    private func resumeDiscovery() {
        memory.resume()
        applyWorkerMode()
    }

    private func applyWorkerMode() {
        let mode: AXWorker.Mode = preferences.barVisible ? .active : .hidden
        let worker = self.worker
        Task { @AXActor in worker.setMode(mode) }
    }

    private func handlePermissionChange(_ permission: PermissionState) {
        switch permission {
        case .denied:
            if !didShowPermissionOnboarding {
                didShowPermissionOnboarding = true
                permissionWindow.show()
            }
        case .revoked:
            barState.showToast("Accessibility permission was revoked")
        case .granted:
            permissionWindow.close()
        case .unknown:
            break
        }
        panelController.relayout()
    }

    /// A hover highlight can outlive the pointer when the target app comes forward over the
    /// bar; drop it whenever the pointer is no longer inside the bar.
    private func clearStaleHover() {
        guard barState.hoveredItem != nil, barState.drag == nil else { return }
        if !panelController.window.frame.contains(NSEvent.mouseLocation) {
            barState.hoveredItem = nil
        }
    }

    // MARK: - Actions

    /// Collapses the bar to its handle or expands it; the auto-hide delay restarts on expand.
    func setCollapsed(_ collapsed: Bool) {
        if collapsed {
            popup.dismiss()
        } else {
            autoHide.noteExpanded()
        }
        panelController.setCollapsed(collapsed)
    }

    func refresh() {
        let worker = self.worker
        Task { @AXActor in worker.requestReconcile(after: .zero) }
    }

    /// Activates a single window or a whole group. For a group every member is raised in
    /// order and the focus target (last focused member, else the first) receives focus last.
    func activate(_ item: BarItemID) {
        popup.dismiss()
        if search.isShown { search.cancel() }
        activationCounter += 1
        let request = activationCounter
        let focus = self.focus

        switch item {
        case .window(let id):
            store.noteFocused(id)
            Task { @MainActor [weak self] in
                let outcome = await focus.focus(id)
                self?.report(outcome, request: request)
            }
        case .group(let groupID):
            guard let group = store.group(groupID), let target = group.focusTarget else { return }
            let others = group.members.filter { $0 != target }
            Task { @MainActor [weak self] in
                for member in others {
                    guard self?.activationCounter == request else { return }
                    _ = await focus.raise(member)
                }
                guard self?.activationCounter == request else { return }
                let outcome = await focus.focus(target)
                self?.report(outcome, request: request)
            }
        }
    }

    private func report(_ outcome: FocusOutcome, request: UInt64) {
        guard activationCounter == request else { return }
        switch outcome {
        case .verified:
            break
        case .unverified(let note):
            if Log.verbose { Log.focus.debug("Focus unverified: \(note, privacy: .public)") }
        case .failed(let failure):
            barState.showToast(failure.message)
            if failure == .windowGone || failure == .processGone { refresh() }
        case .aborted(let reason):
            if Log.verbose { Log.focus.debug("Focus aborted: \(reason, privacy: .public)") }
        }
    }

    private func makeSettingsView() -> AnyView {
        AnyView(SettingsView(
            preferences: preferences,
            store: store,
            persistence: persistence,
            onResetAll: { [unowned self] in confirmResetAll() },
            hotkeySection: AnyView(HotkeySettingsView(model: hotkeyModel))
        ))
    }

    private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all names, badges and groups?"
        alert.informativeText = "Every session name, badge, color and group is removed. Windows themselves are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.resetAllCustomizations()
            memory.forgetEverything()
        }
    }
}
