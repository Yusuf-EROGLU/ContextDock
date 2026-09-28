import ApplicationServices
import Foundation

/// Names of the notifications ContextDock listens to.
enum AXNotificationName {
    static let windowCreated = kAXWindowCreatedNotification as String
    static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
    static let applicationHidden = kAXApplicationHiddenNotification as String
    static let applicationShown = kAXApplicationShownNotification as String
    static let titleChanged = kAXTitleChangedNotification as String
    static let elementDestroyed = kAXUIElementDestroyedNotification as String
    static let windowMiniaturized = kAXWindowMiniaturizedNotification as String
    static let windowDeminiaturized = kAXWindowDeminiaturizedNotification as String

    static let applicationLevel = [windowCreated, focusedWindowChanged, applicationHidden, applicationShown]
    static let windowLevel = [titleChanged, elementDestroyed, windowMiniaturized, windowDeminiaturized]
}

/// Describes one observation target. Immutable, so it is `Sendable`, and it carries only
/// ContextDock's own identifiers — never an AX element. Tokens are never handed to AX as raw
/// pointers; AX receives an integer id that is resolved through `AXObservationRegistry`.
final class AXObservationToken: Sendable {
    let process: ProcessInstanceKey
    let window: WindowSessionID?
    unowned let worker: AXWorker

    init(process: ProcessInstanceKey, window: WindowSessionID?, worker: AXWorker) {
        self.process = process
        self.window = window
        self.worker = worker
    }
}

/// Maps the integer `refcon` values given to AX back to tokens. Because the lookup happens on
/// the AX actor and unknown ids are ignored, a notification that was already queued when its
/// registration was removed can never touch freed memory.
@AXActor
enum AXObservationRegistry {
    private static var tokens: [UInt: AXObservationToken] = [:]
    private static var nextID: UInt = 1

    static func register(_ token: AXObservationToken) -> UInt {
        let id = nextID
        nextID += 1
        tokens[id] = token
        return id
    }

    static func unregister(_ id: UInt) {
        tokens[id] = nil
    }

    static func dispatch(id: UInt, notification: String) {
        guard let token = tokens[id] else { return }
        token.worker.handle(notification: notification, token: token)
    }

#if DEBUG
    static func isRegistered(_ id: UInt) -> Bool { tokens[id] != nil }
#endif
}

/// C callback. Runs on the AX worker thread between executor jobs; it hops back onto the
/// actor with a `Task` because `assumeIsolated` is unavailable for custom executors on macOS 14.
/// The refcon is a plain integer id, never a pointer to an object.
private let observerCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let id = UInt(bitPattern: refcon)
    let name = notification as String
    Task { @AXActor in
        AXObservationRegistry.dispatch(id: id, notification: name)
    }
}

/// One `AXObserver` for one process instance, with its run loop source attached to the AX
/// worker's run loop. Tokens are retained here for as long as their registrations exist.
@AXActor
final class AXObserverHandle {
    private let observer: AXObserver
    private let source: CFRunLoopSource
    private var registrations: [Registration] = []

    private struct Registration {
        let element: AXUIElement
        let notification: String
        let token: AXObservationToken
        let tokenID: UInt
    }
    private var tokenIDs: [ObjectIdentifier: UInt] = [:]

    init?(pid: pid_t) {
        var observer: AXObserver?
        let error = AXObserverCreate(pid, observerCallback, &observer)
        guard error == .success, let observer else {
            Log.ax.debug("AXObserverCreate failed for pid \(pid): \(error.rawValue)")
            return nil
        }
        self.observer = observer
        self.source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    @discardableResult
    func add(_ notification: String, to element: AXUIElement, token: AXObservationToken) -> Bool {
        let tokenID: UInt
        if let existing = tokenIDs[ObjectIdentifier(token)] {
            tokenID = existing
        } else {
            tokenID = AXObservationRegistry.register(token)
            tokenIDs[ObjectIdentifier(token)] = tokenID
        }
        guard let refcon = UnsafeMutableRawPointer(bitPattern: tokenID) else { return false }
        let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        switch error {
        case .success, .notificationAlreadyRegistered:
            registrations.append(Registration(element: element, notification: notification, token: token, tokenID: tokenID))
            return true
        default:
            if Log.verbose {
                Log.ax.debug("AXObserverAddNotification(\(notification)) failed: \(error.rawValue)")
            }
            // `tokenID` was allocated before the AX call. Release it when no successful
            // registration refers to it, otherwise repeated failures leak registry entries.
            releaseUnusedTokens()
            return false
        }
    }

    /// Removes every registration made for the given window id (or app-level ones when `nil`).
    func removeRegistrations(for window: WindowSessionID?) {
        let (toRemove, keep) = registrations.reduce(into: ([Registration](), [Registration]())) { acc, reg in
            if reg.token.window == window { acc.0.append(reg) } else { acc.1.append(reg) }
        }
        for reg in toRemove {
            AXObserverRemoveNotification(observer, reg.element, reg.notification as CFString)
        }
        registrations = keep
        releaseUnusedTokens()
    }

    func invalidate() {
        for reg in registrations {
            AXObserverRemoveNotification(observer, reg.element, reg.notification as CFString)
        }
        registrations.removeAll()
        releaseUnusedTokens()
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    /// Unregisters token ids no registration refers to any more. Late callbacks for those ids
    /// are ignored by the registry.
    private func releaseUnusedTokens() {
        let live = Set(registrations.map(\.tokenID))
        for (object, id) in tokenIDs where !live.contains(id) {
            AXObservationRegistry.unregister(id)
            tokenIDs[object] = nil
        }
    }
}
