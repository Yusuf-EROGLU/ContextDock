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

    // M2: project awareness, search and the global shortcut.
    let git = GitService()
    private(set) lazy var gitScheduler = GitRefreshScheduler(service: git, store: store)
    private(set) lazy var projectBinding = ProjectBindingCoordinator(store: store, barState: barState)
    private(set) lazy var search = SearchPanelController(store: store, preferences: preferences)
    private let hotkeyRegistrar = CarbonHotkeyRegistrar()
    private(set) lazy var hotkeyModel = HotkeyModel(registrar: hotkeyRegistrar, persistence: persistence)
    private var knownProcessKeys: Set<ProcessInstanceKey> = []
    // M3: optional Unity Editor bridge heartbeats.
    private(set) lazy var unityBridge = UnityBridgeMonitor(store: store)

    private var snapshotTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var didShowPermissionOnboarding = false

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
        wireProjectAwareness()
        observeWorkspace()
        observePreferences()

        let worker = self.worker
        let store = self.store
        snapshotTask = Task { @MainActor [weak self] in
            for await snapshot in worker.snapshots {
                store.apply(snapshot)
                self?.updateProcessHints(for: snapshot)
                self?.handlePermissionChange(snapshot.permission)
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
        gitScheduler.setBarVisible(preferences.barVisible)
        gitScheduler.start()
        unityBridge.start()
        hotkeyModel.registerSaved()
        Log.app.info("ContextDock started")
    }

    func shutdown() {
        snapshotTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        persistence.flush()
        let worker = self.worker
        Task { @AXActor in worker.stop() }
    }

    // MARK: - Wiring

    private func wireStatusItem() {
        statusItem.isBarVisible = { [unowned self] in panelController.isShown }
        statusItem.permissionState = { [unowned self] in store.permission }
        statusItem.onToggleBar = { [unowned self] in
            preferences.barVisible.toggle()
        }
        statusItem.onRefresh = { [unowned self] in refresh() }
        statusItem.onSearch = { [unowned self] in search.toggle() }
        statusItem.onSettings = { [unowned self] in settingsWindow.show() }
        statusItem.onPermission = { [unowned self] in permissionWindow.show() }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    private func wirePanel() {
        panelController.onActivate = { [unowned self] id in activate(id) }
        panelController.onMenu = { [unowned self] id in
            cardActions.menu(for: id, anchor: panelController.anchorRect(for: id))
        }
        panelController.onRequestPermission = { [unowned self] in
            AXPermission.requestTrust()
            permissionWindow.show()
        }
        permissionWindow.onRecheck = { [unowned self] in refresh() }
    }

    private func wireProjectAwareness() {
        cardActions.onAttachProject = { [unowned self] id in projectBinding.attach(to: id) }
        projectBinding.onBound = { [unowned self] in gitScheduler.pathsMayHaveChanged() }
        search.onChoose = { [unowned self] id in activate(id) }
        hotkeyRegistrar.onPressed = { [unowned self] in search.toggle() }
    }

    /// Reads Unity `-projectPath` arguments for newly seen Unity processes (optional adapter).
    private func updateProcessHints(for snapshot: DiscoverySnapshot) {
        let keys = Set(snapshot.processes.keys)
        let added = keys.subtracting(knownProcessKeys)
        knownProcessKeys = keys
        guard preferences.readProcessArguments else { return }
        for key in added {
            guard let process = snapshot.processes[key], process.kind.isUnityEditor else { continue }
            let hint = UnityProcessArgumentsAdapter.hint(pid: key.pid)
            if let hint {
                store.setProcessArgumentsHint(hint, for: key)
                if Log.verbose {
                    let pid = key.pid
                    Log.integrations.debug("Unity pid=\(pid) -projectPath found (validation: \(String(describing: hint.validation), privacy: .public))")
                }
            }
        }
    }

    private func wireStoreCallbacks() {
        store.onCardsChanged = { [unowned self] in
            panelController.relayout()
            gitScheduler.pathsMayHaveChanged()
        }
        store.onWindowsRemoved = { [unowned self] removed in
            if let selected = barState.keyboardSelectedCard, removed.contains(selected) {
                barState.keyboardSelectedCard = nil
            }
            if let hovered = barState.hoveredCard, removed.contains(hovered) {
                barState.hoveredCard = nil
            }
            if let editing = cardActions.editingCard, removed.contains(editing) {
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
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: reconcile))
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @AXActor in worker.setMode(.paused) }
            Task { @MainActor in self?.gitScheduler.setPaused(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyWorkerMode() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @AXActor in worker.setMode(.paused) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyWorkerMode() }
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
            panelController.relayout()
        }
        ObservationLoop.observe { [unowned self] in
            let show = preferences.showAuxiliaryWindows
            let worker = self.worker
            Task { @AXActor in worker.setShowAuxiliaryWindows(show) }
        }
    }

    private func applyWorkerMode() {
        let mode: AXWorker.Mode = preferences.barVisible ? .active : .hidden
        let worker = self.worker
        Task { @AXActor in worker.setMode(mode) }
        gitScheduler.setBarVisible(preferences.barVisible)
        gitScheduler.setPaused(false)
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

    // MARK: - Actions

    func refresh() {
        let worker = self.worker
        Task { @AXActor in worker.requestReconcile(after: .zero) }
    }

    func activate(_ id: WindowSessionID) {
        popup.dismiss()
        if search.isShown { search.cancel() }
        let focus = self.focus
        Task { @MainActor [weak self] in
            let outcome = await focus.focus(id)
            guard let self else { return }
            switch outcome {
            case .verified:
                break
            case .unverified(let note):
                if Log.verbose { Log.focus.debug("Focus unverified: \(note, privacy: .public)") }
            case .failed(let failure):
                barState.showToast(failure.message)
                if failure == .windowGone || failure == .processGone {
                    refresh()
                }
            case .aborted(let reason):
                if Log.verbose { Log.focus.debug("Focus aborted: \(reason, privacy: .public)") }
            }
        }
    }

    private func makeSettingsView() -> AnyView {
        AnyView(SettingsView(
            preferences: preferences,
            store: store,
            persistence: persistence,
            onResetAll: { [unowned self] in confirmResetAll() },
            onDeleteRule: { [unowned self] id in store.deleteRule(id: id) },
            hotkeySection: AnyView(HotkeySettingsView(model: hotkeyModel))
        ))
    }

    private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all customizations?"
        alert.informativeText = "Removes every session name, badge and attached folder. Optionally also deletes saved project rules."
        alert.addButton(withTitle: "Reset Session Only")
        alert.addButton(withTitle: "Reset Everything")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn: store.resetAllCustomizations(includingRules: false)
        case .alertSecondButtonReturn: store.resetAllCustomizations(includingRules: true)
        default: break
        }
    }
}
