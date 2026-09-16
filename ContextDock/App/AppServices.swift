import AppKit

/// Composition root: creates the services and wires them together.
@MainActor
final class AppServices {
    let preferences = Preferences()
    let apps = RunningAppsProvider()
    let persistence = PersistenceService()
    let customizations = SessionCustomizationStore()
    let store: WindowStore
    let worker: AXWorker
    let focus: FocusService

    private var snapshotTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

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
    }

    func start() {
        let worker = self.worker
        let store = self.store
        snapshotTask = Task { @MainActor in
            for await snapshot in worker.snapshots {
                store.apply(snapshot)
            }
        }
        Task { @AXActor in
            worker.setShowAuxiliaryWindows(false)
            worker.start()
        }
    }

    func shutdown() {
        snapshotTask?.cancel()
        persistence.flush()
        let worker = self.worker
        Task { @AXActor in worker.stop() }
    }
}
