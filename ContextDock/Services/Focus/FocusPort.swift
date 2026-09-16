import Foundation

/// Result of checking whether a window target is still alive before acting on it.
enum FocusProbe: Sendable, Equatable {
    case alive(pid: pid_t)
    case windowGone
    case processGone
    case notResponding
    case permissionRevoked
}

/// The operations `FocusService` sequences. The live implementation is the AX worker; tests
/// use a scripted mock to assert ordering and retry behaviour.
@AXActor
protocol FocusPort: AnyObject, Sendable {
    func probe(_ id: WindowSessionID) -> FocusProbe
    func frontmostProcessID() -> pid_t?
    func ownProcessID() -> pid_t

    func applicationIsHidden(_ pid: pid_t) -> Bool?
    @discardableResult func setApplicationHidden(_ pid: pid_t, _ hidden: Bool) -> Bool
    func windowIsMinimized(_ id: WindowSessionID) -> Bool?
    @discardableResult func setWindowMinimized(_ id: WindowSessionID, _ minimized: Bool) -> Bool

    /// Requests activation through AppKit on the main actor. The result is advisory.
    func activateApplication(_ pid: pid_t) async -> Bool
    /// Sets `kAXFrontmostAttribute` on the application element.
    @discardableResult func setApplicationFrontmost(_ pid: pid_t) -> Bool
    @discardableResult func raiseWindow(_ id: WindowSessionID) -> Bool
    @discardableResult func setWindowMain(_ id: WindowSessionID) -> Bool
    @discardableResult func setFocusedWindow(_ id: WindowSessionID) -> Bool

    func windowIsFocused(_ id: WindowSessionID) -> Bool?
    func windowIsMain(_ id: WindowSessionID) -> Bool?

    func sleep(for duration: Duration) async
}
