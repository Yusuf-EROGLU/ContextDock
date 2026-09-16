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
        var missedScansBeforeProbe = 2
    }

    fileprivate struct WindowAttributes {
        var role: String?
        var subrole: String?
        var title: String?
        var isMinimized: Bool
        var isMain: Bool
    }

    fileprivate struct TrackedWindow {
        let id: WindowSessionID
        let element: AXUIElement
        var snapshot: WindowSnapshot
        var missedScans: Int
    }

    fileprivate struct AppSession {
        let key: ProcessInstanceKey
        let element: AXUIElement
        var info: ProcessSnapshot
        var launchDate: Date?
        var observer: AXObserverHandle?
        var appToken: AXObservationToken?
        var windows: [WindowSessionID: TrackedWindow]
        var consecutiveFailures: Int
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
    private var pidKeys: [pid_t: ProcessInstanceKey] = [:]
    private var generationCounter: UInt64 = 0
    private var sequenceCounter: UInt64 = 0

    private var mode: Mode = .active
    private var showAuxiliaryWindows = false
    private var permission: PermissionState = .unknown
    private var wasEverTrusted = false
    private var isReconciling = false
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

        guard AXPermission.isTrusted() else {
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
            let key = processKey(for: app)
            seen.insert(key)
            if var session = sessions[key] {
                session.info.isHidden = app.isHidden
                session.info.isActive = app.isActive
                scan(&session)
                sessions[key] = session
            } else {
                var session = makeSession(key: key, app: app)
                scan(&session)
                sessions[key] = session
            }
        }

        for key in Array(sessions.keys) where !seen.contains(key) {
            teardownSession(key)
        }
        for (pid, key) in pidKeys where !seen.contains(key) {
            pidKeys[pid] = nil
        }

        emit(force: regained)
    }

    private func processKey(for app: AppDescriptor) -> ProcessInstanceKey {
        let kernelStart = ProcessStartTime.unixMilliseconds(pid: app.pid, launchDate: app.launchDate)
        if let existing = pidKeys[app.pid] {
            switch (existing.start, kernelStart) {
            case (.unixMilliseconds(let known), .some(let current)) where known == current:
                return existing
            case (.generation, .none):
                return existing
            default:
                // Same pid, different start: the pid was reused by a new process.
                teardownSession(existing)
            }
        }
        let key: ProcessInstanceKey
        if let kernelStart {
            key = ProcessInstanceKey(pid: app.pid, start: .unixMilliseconds(kernelStart))
        } else {
            generationCounter += 1
            key = ProcessInstanceKey(pid: app.pid, start: .generation(generationCounter))
        }
        pidKeys[app.pid] = key
        return key
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
            windows: [:],
            consecutiveFailures: 0
        )
        if let observer = AXObserverHandle(pid: key.pid) {
            let token = AXObservationToken(process: key, window: nil, worker: self)
            for name in AXNotificationName.applicationLevel + [AXNotificationName.windowMiniaturized, AXNotificationName.windowDeminiaturized] {
                observer.add(name, to: element, token: token)
            }
            session.observer = observer
            session.appToken = token
        }
        if Log.verbose {
            Log.ax.debug("Tracking \(app.localizedName, privacy: .public) pid=\(key.pid)")
        }
        return session
    }

    private func teardownSession(_ key: ProcessInstanceKey) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.observer?.invalidate()
        for id in session.windows.keys {
            windowIndex[id] = nil
        }
        debouncer.cancel(.rescan(key))
        debouncer.cancel(.focus(key))
        if pidKeys[key.pid] == key {
            pidKeys[key.pid] = nil
        }
    }

    private func teardownAllSessions() {
        for key in Array(sessions.keys) {
            teardownSession(key)
        }
        windowIndex.removeAll()
        pidKeys.removeAll()
    }

    // MARK: - Scanning

    private func scan(_ session: inout AppSession) {
        switch AXElement.elements(session.element, kAXWindowsAttribute as String) {
        case .failure(let failure):
            if failure == .notTrusted {
                permissionLost()
                return
            }
            session.consecutiveFailures += 1
            markStale(&session)
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
                    markStale(&session)
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

            let tracked = session.windows.values
                .sorted { $0.snapshot.firstSeenSequence < $1.snapshot.firstSeenSequence }
                .map { (id: $0.id, element: $0.element) }
            let outcome = WindowMatcher.match(tracked: tracked, fresh: fresh.map(\.element))

            for (id, index) in outcome.matched {
                guard var window = session.windows[id] else { continue }
                apply(fresh[index].attributes, to: &window.snapshot)
                window.snapshot.isStale = false
                window.snapshot.listedByApplication = true
                window.missedScans = 0
                session.windows[id] = window
            }

            for index in outcome.unmatchedFresh {
                let entry = fresh[index]
                let window = track(entry.element, attributes: entry.attributes, in: &session)
                session.windows[window.id] = window
            }

            for id in outcome.missing {
                guard var window = session.windows[id] else { continue }
                window.missedScans += 1
                if window.missedScans >= configuration.missedScansBeforeProbe {
                    switch AXElement.string(window.element, kAXRoleAttribute as String) {
                    case .failure(.invalidElement):
                        untrack(id, in: &session)
                        continue
                    case .failure(.notResponding):
                        window.snapshot.isStale = true
                    default:
                        window.snapshot.listedByApplication = false
                    }
                }
                session.windows[id] = window
            }

            refreshFocusFlags(&session)
        }
    }

    private func readAttributes(_ element: AXUIElement) -> Result<WindowAttributes, AXFailure> {
        let role: String?
        switch AXElement.string(element, kAXRoleAttribute as String) {
        case .success(let value): role = value
        case .failure(let failure) where failure == .notResponding || failure == .invalidElement || failure == .notTrusted:
            return .failure(failure)
        case .failure: role = nil
        }
        guard role == WindowFilter.windowRole else {
            return .success(WindowAttributes(role: role, subrole: nil, title: nil, isMinimized: false, isMain: false))
        }

        let subrole = optional(AXElement.string(element, kAXSubroleAttribute as String))
        let title = optional(AXElement.string(element, kAXTitleAttribute as String))
        let minimized = optional(AXElement.bool(element, kAXMinimizedAttribute as String)) ?? false
        let main = optional(AXElement.bool(element, kAXMainAttribute as String)) ?? false
        return .success(WindowAttributes(role: role, subrole: subrole, title: title, isMinimized: minimized, isMain: main))
    }

    private func optional<T>(_ result: Result<T?, AXFailure>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func apply(_ attributes: WindowAttributes, to snapshot: inout WindowSnapshot) {
        snapshot.role = attributes.role
        snapshot.subrole = attributes.subrole
        snapshot.title = attributes.title
        snapshot.isMinimized = attributes.isMinimized
        snapshot.isMain = attributes.isMain
    }

    private func track(_ element: AXUIElement, attributes: WindowAttributes, in session: inout AppSession) -> TrackedWindow {
        sequenceCounter += 1
        let id = WindowSessionID()
        AXElement.setTimeout(element, seconds: configuration.elementTimeoutSeconds)
        var snapshot = WindowSnapshot(
            id: id,
            process: session.key,
            firstSeenSequence: sequenceCounter,
            title: nil,
            role: nil,
            subrole: nil,
            isMinimized: false,
            isMain: false,
            isFocused: false,
            isStale: false,
            listedByApplication: true
        )
        apply(attributes, to: &snapshot)
        let window = TrackedWindow(id: id, element: element, snapshot: snapshot, missedScans: 0)
        windowIndex[id] = session.key

        if let observer = session.observer {
            let token = AXObservationToken(process: session.key, window: id, worker: self)
            for name in [AXNotificationName.titleChanged, AXNotificationName.elementDestroyed] {
                observer.add(name, to: element, token: token)
            }
        }
        return window
    }

    private func untrack(_ id: WindowSessionID, in session: inout AppSession) {
        session.observer?.removeRegistrations(for: id)
        session.windows[id] = nil
        windowIndex[id] = nil
        debouncer.cancel(.title(id))
    }

    private func markStale(_ session: inout AppSession) {
        for id in session.windows.keys {
            session.windows[id]?.snapshot.isStale = true
        }
    }

    private func refreshFocusFlags(_ session: inout AppSession) {
        guard case .success(let focused) = AXElement.element(session.element, kAXFocusedWindowAttribute as String) else { return }
        for id in session.windows.keys {
            guard let window = session.windows[id] else { continue }
            let isFocused = focused.map { AXElement.isSame($0, window.element) } ?? false
            session.windows[id]?.snapshot.isFocused = isFocused
        }
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
            untrack(windowID, in: &session)
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
        sessions[key] = session
        emit()
    }

    private func refreshTitle(process key: ProcessInstanceKey, window id: WindowSessionID) {
        guard var session = sessions[key], var window = session.windows[id] else { return }
        switch AXElement.string(window.element, kAXTitleAttribute as String) {
        case .success(let title):
            window.snapshot.title = title
            window.snapshot.isStale = false
            session.windows[id] = window
        case .failure(.invalidElement):
            untrack(id, in: &session)
        case .failure:
            break
        }
        sessions[key] = session
        emit()
    }

    private func refreshFocus(process key: ProcessInstanceKey) {
        guard var session = sessions[key] else { return }
        refreshFocusFlags(&session)
        for id in session.windows.keys {
            guard let window = session.windows[id] else { continue }
            if case .success(let main) = AXElement.bool(window.element, kAXMainAttribute as String) {
                session.windows[id]?.snapshot.isMain = main ?? false
            }
        }
        sessions[key] = session
        emit()
    }

    // MARK: - Snapshot emission

    private func buildSnapshot() -> DiscoverySnapshot {
        var processes: [ProcessInstanceKey: ProcessSnapshot] = [:]
        var windows: [WindowSnapshot] = []
        for session in sessions.values {
            processes[session.key] = session.info
            windows.append(contentsOf: session.windows.values.map(\.snapshot))
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

    fileprivate func tracked(_ id: WindowSessionID) -> (session: AppSession, window: TrackedWindow)? {
        guard let key = windowIndex[id], let session = sessions[key], let window = session.windows[id] else { return nil }
        return (session, window)
    }

    fileprivate func session(pid: pid_t) -> AppSession? {
        guard let key = pidKeys[pid] else { return nil }
        return sessions[key]
    }

    fileprivate func removeDeadWindow(_ id: WindowSessionID) {
        guard let key = windowIndex[id], var session = sessions[key] else { return }
        untrack(id, in: &session)
        sessions[key] = session
        emit()
    }
}

// MARK: - FocusPort (live implementation)

extension AXWorker: FocusPort {
    func probe(_ id: WindowSessionID) -> FocusProbe {
        guard let (session, window) = tracked(id) else { return .windowGone }
        let pid = session.key.pid
        if let expected = session.key.startUnixMilliseconds,
           let current = ProcessStartTime.unixMilliseconds(pid: pid, launchDate: session.launchDate),
           current != expected {
            teardownSession(session.key)
            emit()
            return .processGone
        }
        switch AXElement.string(window.element, kAXRoleAttribute as String) {
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
        guard let (_, window) = tracked(id) else { return nil }
        if case .success(let minimized) = AXElement.bool(window.element, kAXMinimizedAttribute as String) {
            return minimized
        }
        return nil
    }

    func setWindowMinimized(_ id: WindowSessionID, _ minimized: Bool) -> Bool {
        guard let (_, window) = tracked(id) else { return false }
        if case .success = AXElement.setBool(window.element, kAXMinimizedAttribute as String, minimized) {
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
        guard let (_, window) = tracked(id) else { return false }
        AXElement.setTimeout(window.element, seconds: 2.0)
        defer { AXElement.setTimeout(window.element, seconds: configuration.elementTimeoutSeconds) }
        if case .success = AXElement.perform(window.element, kAXRaiseAction as String) {
            return true
        }
        return false
    }

    func setWindowMain(_ id: WindowSessionID) -> Bool {
        guard let (_, window) = tracked(id) else { return false }
        if case .success = AXElement.setBool(window.element, kAXMainAttribute as String, true) {
            return true
        }
        return false
    }

    func setFocusedWindow(_ id: WindowSessionID) -> Bool {
        guard let (session, window) = tracked(id) else { return false }
        if case .success = AXElement.setElement(session.element, kAXFocusedWindowAttribute as String, window.element) {
            return true
        }
        return false
    }

    func windowIsFocused(_ id: WindowSessionID) -> Bool? {
        guard let (session, window) = tracked(id) else { return nil }
        switch AXElement.element(session.element, kAXFocusedWindowAttribute as String) {
        case .success(let focused):
            guard let focused else { return false }
            return AXElement.isSame(focused, window.element)
        case .failure:
            return nil
        }
    }

    func windowIsMain(_ id: WindowSessionID) -> Bool? {
        guard let (_, window) = tracked(id) else { return nil }
        if case .success(let main) = AXElement.bool(window.element, kAXMainAttribute as String) {
            return main
        }
        return nil
    }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
