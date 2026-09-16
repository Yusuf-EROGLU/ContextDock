import ApplicationServices
import Foundation

extension AXUIElement: ElementIdentity {
    func isSameElement(as other: AXUIElement) -> Bool {
        CFEqual(self, other)
    }
}

/// Main-actor hooks the worker needs from AppKit, passed in as Sendable closures.
struct MainActorAppControl: Sendable {
    let runningApps: @MainActor @Sendable () -> [AppDescriptor]
    let activate: @MainActor @Sendable (pid_t) -> Bool
    let unhide: @MainActor @Sendable (pid_t) -> Bool
}

/// Discovers accessible windows, keeps session identities stable, observes AX notifications
/// and publishes plain `DiscoverySnapshot` values. Everything here runs on `AXActor`.
@AXActor
final class AXWorker {
    enum Mode: Sendable, Equatable {
        case active
        case hidden
        case paused
    }

    struct Configuration: Sendable {
        var activeInterval: Duration = .seconds(2.5)
        var hiddenInterval: Duration = .seconds(10)
        var notificationDebounce: Duration = .milliseconds(150)
        var titleDebounce: Duration = .milliseconds(100)
        var elementTimeoutSeconds: Float = 1.0
        /// Apps that deliver AX notifications are re-scanned only every N ticks; the frontmost
        /// app and apps without a working observer are scanned every tick.
        var observedAppScanEveryTicks = 4
        /// Trust is re-checked every N ticks while granted (AX errors also reveal revocation).
        var trustCheckEveryTicks = 4
    }

    fileprivate struct AppSession {
        let key: ProcessInstanceKey
        let element: AXUIElement
        var info: ProcessSnapshot
        var launchDate: Date?
        var observer: AXObserverHandle?
        var appToken: AXObservationToken?
        var tracker: WindowTracker<AXUIElement>
        var consecutiveFailures: Int
        var lastScanTick: UInt64 = 0
    }

    private enum DebounceKey: Hashable, Sendable {
        case rescan(ProcessInstanceKey)
        case focus(ProcessInstanceKey)
        case title(WindowSessionID)
        case reconcile
    }

    let snapshots: AsyncStream<DiscoverySnapshot>
    private let continuation: AsyncStream<DiscoverySnapshot>.Continuation

    private let control: MainActorAppControl
    private var configuration: Configuration
    private let systemWide = AXUIElementCreateSystemWide()
    private let debouncer = Debouncer<DebounceKey>()

    private var sessions: [ProcessInstanceKey: AppSession] = [:]
    private var windowIndex: [WindowSessionID: ProcessInstanceKey] = [:]
    private var keyResolver = ProcessInstanceKeyResolver()
    private var sequenceCounter: UInt64 = 0

    private var mode: Mode = .active
    private var showAuxiliaryWindows = false
    private var permission: PermissionState = .unknown
    private var wasEverTrusted = false
    private var isReconciling = false
    private var tick: UInt64 = 0
    private var lastEmitted: DiscoverySnapshot?
    private var loopTask: Task<Void, Never>?

    nonisolated init(control: MainActorAppControl, configuration: Configuration = Configuration()) {
        self.control = control
        self.configuration = configuration
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoverySnapshot.self, bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    func start() {
        guard loopTask == nil else { return }
        AXElement.setTimeout(systemWide, seconds: configuration.elementTimeoutSeconds)
        loopTask = Task { @AXActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcile()
                let interval: Duration
                switch self.mode {
                case .active: interval = self.configuration.activeInterval
                case .hidden: interval = self.configuration.hiddenInterval
                case .paused: interval = .seconds(1)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        debouncer.cancelAll()
        teardownAllSessions()
    }

    func setMode(_ newMode: Mode) {
        let wasPaused = mode == .paused
        mode = newMode
        if wasPaused && newMode != .paused {
            requestReconcile(after: .seconds(2))
        }
    }

    func setShowAuxiliaryWindows(_ show: Bool) {
        guard show != showAuxiliaryWindows else { return }
        showAuxiliaryWindows = show
        requestReconcile(after: .zero)
    }

    /// Schedules a full reconciliation (debounced). Used for refresh, workspace notifications
    /// and permission re-checks.
    func requestReconcile(after delay: Duration = .milliseconds(150)) {
        debouncer.schedule(.reconcile, after: delay) { [weak self] in
            await self?.reconcile()
        }
    }

    // MARK: - Reconciliation

    func reconcile() async {
        guard mode != .paused, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        tick += 1

        let mustCheckTrust = permission != .granted || tick % UInt64(configuration.trustCheckEveryTicks) == 0
        guard !mustCheckTrust || AXPermission.isTrusted() else {
            let state: PermissionState = wasEverTrusted ? .revoked : .denied
            if permission != state || !sessions.isEmpty {
                teardownAllSessions()
                permission = state
                emit(force: true)
            }
            return
        }
        let regained = permission != .granted
        permission = .granted
        wasEverTrusted = true

        let apps = await MainActor.run { control.runningApps() }
        guard mode != .paused else { return }

        var seen = Set<ProcessInstanceKey>()
        for app in apps {
            let resolution = keyResolver.resolve(pid: app.pid, launchDate: app.launchDate)
            if let replaced = resolution.replaced {
                // Same pid, different start time: a new process reused the pid.
                teardownSession(replaced)
            }
            let key = resolution.key
            seen.insert(key)
            if var session = sessions[key] {
                session.info.isHidden = app.isHidden
                session.info.isActive = app.isActive
                if isScanDue(session, isActive: app.isActive) {
                    scan(&session)
                    session.lastScanTick = tick
                }
                sessions[key] = session
            } else {
                var session = makeSession(key: key, app: app)
                scan(&session)
                session.lastScanTick = tick
                sessions[key] = session
            }
        }

        for key in Array(sessions.keys) where !seen.contains(key) {
            teardownSession(key)
        }
        for key in keyResolver.knownKeys where !seen.contains(key) {
            keyResolver.forget(key)
        }

        emit(force: regained)
    }

    /// Notification-backed apps are polled less often; everything else every tick.
    private func isScanDue(_ session: AppSession, isActive: Bool) -> Bool {
        if session.observer == nil || isActive || session.consecutiveFailures > 0 { return true }
        return tick - session.lastScanTick >= UInt64(configuration.observedAppScanEveryTicks)
    }

    private func makeSession(key: ProcessInstanceKey, app: AppDescriptor) -> AppSession {
        let element = AXUIElementCreateApplication(key.pid)
        AXElement.setTimeout(element, seconds: configuration.elementTimeoutSeconds)
        let info = ProcessSnapshot(
            key: key,
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName,
            kind: ApplicationKind(bundleIdentifier: app.bundleIdentifier),
            isHidden: app.isHidden,
            isActive: app.isActive
        )
        var session = AppSession(
            key: key,
            element: element,
            info: info,
            launchDate: app.launchDate,
            observer: nil,
            appToken: nil,
            tracker: WindowTracker(process: key),
            consecutiveFailures: 0
        )
        if let observer = AXObserverHandle(pid: key.pid) {
            let token = AXObservationToken(process: key, window: nil, worker: self)
            let names = AXNotificationName.applicationLevel + [AXNotificationName.windowMiniaturized, AXNotificationName.windowDeminiaturized]
            for name in names {
                observer.add(name, to: element, token: token)
            }
            session.observer = observer
            session.appToken = token
        }
        if Log.verbose {
            let name = app.localizedName
            let pid = key.pid
            Log.ax.debug("Tracking \(name, privacy: .public) pid=\(pid)")
        }
        return session
    }

    private func teardownSession(_ key: ProcessInstanceKey) {
        guard var session = sessions.removeValue(forKey: key) else { return }
        session.observer?.invalidate()
        for id in session.tracker.removeAll() {
            windowIndex[id] = nil
            debouncer.cancel(.title(id))
        }
        debouncer.cancel(.rescan(key))
        debouncer.cancel(.focus(key))
        keyResolver.forget(key)
    }

    private func teardownAllSessions() {
        for key in Array(sessions.keys) {
            teardownSession(key)
        }
        windowIndex.removeAll()
        keyResolver.forgetAll()
    }

    // MARK: - Scanning

    private func scan(_ session: inout AppSession) {
        let input: WindowTracker<AXUIElement>.ScanInput
        switch AXElement.elements(session.element, kAXWindowsAttribute as String) {
        case .failure(let failure):
            if failure == .notTrusted {
                permissionLost()
                return
            }
            session.consecutiveFailures += 1
            input = .failure
            if Log.verbose {
                let pid = session.key.pid
                let description = String(describing: failure)
                Log.ax.debug("Window list failed for pid=\(pid): \(description, privacy: .public)")
            }

        case .success(let elements):
            var fresh: [(element: AXUIElement, attributes: WindowAttributes)] = []
            for element in elements {
                switch readAttributes(element) {
                case .failure(.notResponding):
                    session.consecutiveFailures += 1
                    _ = session.tracker.apply(.failure, nextSequence: { 0 }, probe: { _ in .alive })
                    return
                case .failure(.notTrusted):
                    permissionLost()
                    return
                case .failure:
                    continue
                case .success(let attributes):
                    if WindowFilter.shouldTrack(role: attributes.role, subrole: attributes.subrole, showAuxiliary: showAuxiliaryWindows) {
                        fresh.append((element, attributes))
                    }
                }
            }
            session.consecutiveFailures = 0
            input = .success(fresh)
        }

        let changes = session.tracker.apply(
            input,
            nextSequence: { sequenceCounter += 1; return sequenceCounter },
            probe: { element in
                switch AXElement.string(element, kAXRoleAttribute as String) {
                case .failure(.invalidElement): return .dead
                case .failure(.notResponding): return .notResponding
                default: return .alive
                }
            }
        )

        for id in changes.added {
            windowIndex[id] = session.key
            if let element = session.tracker.element(for: id) {
                AXElement.setTimeout(element, seconds: configuration.elementTimeoutSeconds)
                if let observer = session.observer {
                    let token = AXObservationToken(process: session.key, window: id, worker: self)
                    for name in [AXNotificationName.titleChanged, AXNotificationName.elementDestroyed] {
                        observer.add(name, to: element, token: token)
                    }
                }
            }
        }
        for id in changes.removed {
            forgetWindow(id, in: &session)
        }

        if case .success = input {
            refreshFocusFlags(&session)
        }
    }

    private static let windowAttributeNames = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXTitleAttribute as String,
        kAXMinimizedAttribute as String,
        kAXMainAttribute as String,
    ]

    /// One IPC per window instead of five: role, subrole, title, minimized and main together.
    private func readAttributes(_ element: AXUIElement) -> Result<WindowAttributes, AXFailure> {
        switch AXElement.copyAttributes(element, Self.windowAttributeNames) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let values):
            let role = AXElement.stringValue(values[0])
            guard role == WindowFilter.windowRole else {
                return .success(WindowAttributes(role: role, subrole: nil, title: nil, isMinimized: false, isMain: false))
            }
            return .success(WindowAttributes(
                role: role,
                subrole: AXElement.stringValue(values[1]),
                title: AXElement.stringValue(values[2]),
                isMinimized: AXElement.boolValue(values[3]) ?? false,
                isMain: AXElement.boolValue(values[4]) ?? false
            ))
        }
    }

    private func optional<T>(_ result: Result<T?, AXFailure>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func forgetWindow(_ id: WindowSessionID, in session: inout AppSession) {
        session.observer?.removeRegistrations(for: id)
        session.tracker.remove(id)
        windowIndex[id] = nil
        debouncer.cancel(.title(id))
    }

    private func refreshFocusFlags(_ session: inout AppSession) {
        guard case .success(let focused) = AXElement.element(session.element, kAXFocusedWindowAttribute as String) else { return }
        session.tracker.setFocused(focused)
    }

    private func permissionLost() {
        Log.ax.notice("Accessibility permission lost; pausing discovery")
        teardownAllSessions()
        permission = .revoked
        emit(force: true)
    }

    // MARK: - Notifications

    func handle(notification: String, token: AXObservationToken) {
        guard sessions[token.process] != nil else { return }
        let key = token.process

        switch notification {
        case AXNotificationName.elementDestroyed:
            guard let windowID = token.window, var session = sessions[key] else { return }
            forgetWindow(windowID, in: &session)
            sessions[key] = session
            emit()

        case AXNotificationName.titleChanged:
            guard let windowID = token.window else { return }
            debouncer.schedule(.title(windowID), after: configuration.titleDebounce) { [weak self] in
                self?.refreshTitle(process: key, window: windowID)
            }

        case AXNotificationName.focusedWindowChanged:
            debouncer.schedule(.focus(key), after: configuration.titleDebounce) { [weak self] in
                self?.refreshFocus(process: key)
            }

        default:
            debouncer.schedule(.rescan(key), after: configuration.notificationDebounce) { [weak self] in
                self?.rescan(process: key)
            }
        }
    }

    private func rescan(process key: ProcessInstanceKey) {
        guard mode != .paused, var session = sessions[key] else { return }
        scan(&session)
        session.lastScanTick = tick
        sessions[key] = session
        emit()
    }

    private func refreshTitle(process key: ProcessInstanceKey, window id: WindowSessionID) {
        guard var session = sessions[key], let element = session.tracker.element(for: id) else { return }
        switch AXElement.string(element, kAXTitleAttribute as String) {
        case .success(let title):
            session.tracker.updateTitle(id, title: title)
        case .failure(.invalidElement):
            forgetWindow(id, in: &session)
        case .failure:
            break
        }
        sessions[key] = session
        emit()
    }

    private func refreshFocus(process key: ProcessInstanceKey) {
        guard var session = sessions[key] else { return }
        refreshFocusFlags(&session)
        for snapshot in session.tracker.snapshots {
            guard let element = session.tracker.element(for: snapshot.id) else { continue }
            if case .success(let main) = AXElement.bool(element, kAXMainAttribute as String) {
                session.tracker.updateMain(snapshot.id, isMain: main ?? false)
            }
        }
        sessions[key] = session
        emit()
    }

    // MARK: - Snapshot emission

    private func buildSnapshot() -> DiscoverySnapshot {
        var processes: [ProcessInstanceKey: ProcessSnapshot] = [:]
        var windows: [WindowSnapshot] = []
        // The AX system-wide focused application is the freshest "active app" signal; the
        // NSWorkspace value can lag behind the switch by a scan interval.
        let frontmost = frontmostProcessID()
        for session in sessions.values {
            var info = session.info
            if let frontmost { info.isActive = session.key.pid == frontmost }
            processes[session.key] = info
            windows.append(contentsOf: session.tracker.snapshots)
        }
        windows.sort { $0.firstSeenSequence < $1.firstSeenSequence }
        return DiscoverySnapshot(processes: processes, windows: windows, permission: permission, generatedAt: Date())
    }

    private func emit(force: Bool = false) {
        let snapshot = buildSnapshot()
        if !force, let last = lastEmitted,
           last.processes == snapshot.processes,
           last.windows == snapshot.windows,
           last.permission == snapshot.permission {
            return
        }
        lastEmitted = snapshot
        continuation.yield(snapshot)
    }

    // MARK: - Lookup helpers used by the focus port

    fileprivate func tracked(_ id: WindowSessionID) -> (session: AppSession, element: AXUIElement)? {
        guard let key = windowIndex[id], let session = sessions[key], let element = session.tracker.element(for: id) else { return nil }
        return (session, element)
    }

    fileprivate func session(pid: pid_t) -> AppSession? {
        guard let key = keyResolver.key(forPid: pid) else { return nil }
        return sessions[key]
    }

    fileprivate func removeDeadWindow(_ id: WindowSessionID) {
        guard let key = windowIndex[id], var session = sessions[key] else { return }
        forgetWindow(id, in: &session)
        sessions[key] = session
        emit()
    }
}

// MARK: - FocusPort (live implementation)

extension AXWorker: FocusPort {
    func probe(_ id: WindowSessionID) -> FocusProbe {
        guard let (session, element) = tracked(id) else { return .windowGone }
        let pid = session.key.pid
        if let expected = session.key.startUnixMilliseconds,
           let current = ProcessStartTime.unixMilliseconds(pid: pid, launchDate: session.launchDate),
           current != expected {
            teardownSession(session.key)
            emit()
            return .processGone
        }
        switch AXElement.string(element, kAXRoleAttribute as String) {
        case .success:
            return .alive(pid: pid)
        case .failure(.invalidElement):
            removeDeadWindow(id)
            return .windowGone
        case .failure(.notResponding):
            return .notResponding
        case .failure(.notTrusted):
            permissionLost()
            return .permissionRevoked
        case .failure:
            return .alive(pid: pid)
        }
    }

    func frontmostProcessID() -> pid_t? {
        guard case .success(let app?) = AXElement.element(systemWide, kAXFocusedApplicationAttribute as String) else { return nil }
        return AXElement.pid(of: app)
    }

    func ownProcessID() -> pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    func applicationIsHidden(_ pid: pid_t) -> Bool? {
        guard let session = session(pid: pid) else { return nil }
        if case .success(let hidden) = AXElement.bool(session.element, kAXHiddenAttribute as String) {
            return hidden
        }
        return session.info.isHidden
    }

    func setApplicationHidden(_ pid: pid_t, _ hidden: Bool) -> Bool {
        guard let session = session(pid: pid) else { return false }
        if case .success = AXElement.setBool(session.element, kAXHiddenAttribute as String, hidden) {
            return true
        }
        let unhide = control.unhide
        Task { @MainActor in _ = unhide(pid) }
        return false
    }

    func windowIsMinimized(_ id: WindowSessionID) -> Bool? {
        guard let (_, element) = tracked(id) else { return nil }
        if case .success(let minimized) = AXElement.bool(element, kAXMinimizedAttribute as String) {
            return minimized
        }
        return nil
    }

    func setWindowMinimized(_ id: WindowSessionID, _ minimized: Bool) -> Bool {
        guard let (_, element) = tracked(id) else { return false }
        if case .success = AXElement.setBool(element, kAXMinimizedAttribute as String, minimized) {
            return true
        }
        return false
    }

    func activateApplication(_ pid: pid_t) async -> Bool {
        let activate = control.activate
        return await MainActor.run { activate(pid) }
    }

    func setApplicationFrontmost(_ pid: pid_t) -> Bool {
        guard let session = session(pid: pid) else { return false }
        if case .success = AXElement.setBool(session.element, kAXFrontmostAttribute as String, true) {
            return true
        }
        return false
    }

    func raiseWindow(_ id: WindowSessionID) -> Bool {
        guard let (_, element) = tracked(id) else { return false }
        AXElement.setTimeout(element, seconds: 2.0)
        defer { AXElement.setTimeout(element, seconds: configuration.elementTimeoutSeconds) }
        if case .success = AXElement.perform(element, kAXRaiseAction as String) {
            return true
        }
        return false
    }

    func setWindowMain(_ id: WindowSessionID) -> Bool {
        guard let (_, element) = tracked(id) else { return false }
        if case .success = AXElement.setBool(element, kAXMainAttribute as String, true) {
            return true
        }
        return false
    }

    func setFocusedWindow(_ id: WindowSessionID) -> Bool {
        guard let (session, element) = tracked(id) else { return false }
        if case .success = AXElement.setElement(session.element, kAXFocusedWindowAttribute as String, element) {
            return true
        }
        return false
    }

    func windowIsFocused(_ id: WindowSessionID) -> Bool? {
        guard let (session, element) = tracked(id) else { return nil }
        switch AXElement.element(session.element, kAXFocusedWindowAttribute as String) {
        case .success(let focused):
            guard let focused else { return false }
            return AXElement.isSame(focused, element)
        case .failure:
            return nil
        }
    }

    func windowIsMain(_ id: WindowSessionID) -> Bool? {
        guard let (_, element) = tracked(id) else { return nil }
        if case .success(let main) = AXElement.bool(element, kAXMainAttribute as String) {
            return main
        }
        return nil
    }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
