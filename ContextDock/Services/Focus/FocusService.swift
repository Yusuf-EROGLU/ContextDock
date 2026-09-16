import Foundation

enum FocusFailure: Sendable, Equatable {
    case windowGone
    case processGone
    case appNotResponding
    case activationRejected
    case raiseFailed
    case permissionRevoked

    var message: String {
        switch self {
        case .windowGone: return "Window closed"
        case .processGone: return "Application has quit"
        case .appNotResponding: return "Application is not responding"
        case .activationRejected: return "Application could not be activated"
        case .raiseFailed: return "Could not raise the window (a modal dialog may be open)"
        case .permissionRevoked: return "Accessibility permission was revoked"
        }
    }
}

enum FocusOutcome: Sendable, Equatable {
    /// Frontmost app and focused AX window both match the target.
    case verified
    /// Frontmost app matches and the window is main, but focus could not be confirmed.
    case unverified(String)
    case failed(FocusFailure)
    case aborted(String)

    var isSuccess: Bool {
        switch self {
        case .verified, .unverified: return true
        case .failed, .aborted: return false
        }
    }
}

/// Switches to a specific window and verifies the result. Never re-targets another window
/// with the same title, never relaunches an app, and retries at most once.
@AXActor
final class FocusService {
    private let port: any FocusPort
    private var requestCounter: UInt64 = 0
    private var latestRequest: UInt64 = 0

    var verificationAttempts = 8
    var verificationInterval: Duration = .milliseconds(50)
    var unminimizeAttempts = 6

    nonisolated init(port: any FocusPort) {
        self.port = port
    }

    func focus(_ id: WindowSessionID) async -> FocusOutcome {
        requestCounter += 1
        let request = requestCounter
        latestRequest = request

        let pid: pid_t
        switch port.probe(id) {
        case .alive(let alivePid): pid = alivePid
        case .windowGone: return .failed(.windowGone)
        case .processGone: return .failed(.processGone)
        case .notResponding: return .failed(.appNotResponding)
        case .permissionRevoked: return .failed(.permissionRevoked)
        }

        let frontBefore = port.frontmostProcessID()
        let ownPid = port.ownProcessID()

        var attempt = 0
        while true {
            attempt += 1
            let outcome = await attemptOnce(id: id, pid: pid)
            if outcome.isSuccess || attempt >= 2 {
                return outcome
            }
            guard latestRequest == request else {
                return .aborted("Superseded by a newer request")
            }
            if let front = port.frontmostProcessID(), front != pid, front != ownPid, front != frontBefore {
                return .aborted("Cancelled because another window was activated")
            }
            switch port.probe(id) {
            case .alive: break
            case .windowGone: return .failed(.windowGone)
            case .processGone: return .failed(.processGone)
            case .notResponding: return .failed(.appNotResponding)
            case .permissionRevoked: return .failed(.permissionRevoked)
            }
        }
    }

    /// Brings a window forward without the verification loop. Used for the non-focused members
    /// when a group opens; the group's focus target then goes through `focus(_:)`.
    func raise(_ id: WindowSessionID) async -> Bool {
        guard case .alive(let pid) = port.probe(id) else { return false }
        if port.applicationIsHidden(pid) == true { port.setApplicationHidden(pid, false) }
        if port.windowIsMinimized(id) == true { port.setWindowMinimized(id, false) }
        _ = await port.activateApplication(pid)
        let raised = port.raiseWindow(id)
        port.setWindowMain(id)
        return raised
    }

    private func attemptOnce(id: WindowSessionID, pid: pid_t) async -> FocusOutcome {
        if port.applicationIsHidden(pid) == true {
            port.setApplicationHidden(pid, false)
        }

        if port.windowIsMinimized(id) == true {
            port.setWindowMinimized(id, false)
            var waited = 0
            while port.windowIsMinimized(id) == true, waited < unminimizeAttempts {
                waited += 1
                await port.sleep(for: verificationInterval)
            }
        }

        let activated = await port.activateApplication(pid)
        let raised = port.raiseWindow(id)
        port.setWindowMain(id)
        port.setFocusedWindow(id)
        if port.frontmostProcessID() != pid {
            port.setApplicationFrontmost(pid)
        }

        var sawMain = false
        var focusUnsupported = false
        for _ in 0..<verificationAttempts {
            let front = port.frontmostProcessID()
            let focused = port.windowIsFocused(id)
            if front == pid, focused == true {
                return .verified
            }
            if focused == nil {
                focusUnsupported = true
                if front == pid, port.windowIsMain(id) == true {
                    sawMain = true
                    break
                }
            }
            await port.sleep(for: verificationInterval)
        }

        if sawMain {
            return .unverified("Window is main; focus could not be confirmed")
        }
        if focusUnsupported, port.frontmostProcessID() == pid, raised {
            return .unverified("Application does not report window focus")
        }
        if port.frontmostProcessID() != pid {
            return .failed(activated || raised ? .activationRejected : .activationRejected)
        }
        return .failed(.raiseFailed)
    }
}
