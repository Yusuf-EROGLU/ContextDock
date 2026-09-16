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

/// Passed to AX as the observer `refcon`. Immutable, so it is `Sendable`, and it carries only
/// ContextDock's own identifiers — never an AX element.
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

/// C callback. Runs on the AX worker thread between executor jobs; it hops back onto the
/// actor with a `Task` because `assumeIsolated` is unavailable for custom executors on macOS 14.
private let observerCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let token = Unmanaged<AXObservationToken>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    Task { @AXActor in
        token.worker.handle(notification: name, token: token)
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
    }

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
        let refcon = Unmanaged.passUnretained(token).toOpaque()
        let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        switch error {
        case .success:
            registrations.append(Registration(element: element, notification: notification, token: token))
            return true
        case .notificationAlreadyRegistered:
            return true
        default:
            if Log.verbose {
                Log.ax.debug("AXObserverAddNotification(\(notification)) failed: \(error.rawValue)")
            }
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
    }

    func invalidate() {
        for reg in registrations {
            AXObserverRemoveNotification(observer, reg.element, reg.notification as CFString)
        }
        registrations.removeAll()
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }
}
