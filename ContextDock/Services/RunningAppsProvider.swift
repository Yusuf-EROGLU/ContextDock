import AppKit

/// Main-actor wrapper around `NSWorkspace`/`NSRunningApplication`. Produces Sendable descriptors
/// for the AX worker and performs AppKit-side activation on request.
@MainActor
final class RunningAppsProvider {
    private var iconCache: [pid_t: NSImage] = [:]

    init() {}

    func descriptors() -> [AppDescriptor] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPid,
                  !app.isTerminated else { return nil }
            return AppDescriptor(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                launchDate: app.launchDate,
                isHidden: app.isHidden,
                isActive: app.isActive
            )
        }
    }

    func icon(for pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon else { return nil }
        iconCache[pid] = icon
        return icon
    }

    func forgetIcon(for pid: pid_t) {
        iconCache[pid] = nil
    }

    /// Cooperative activation (macOS 14+). The return value only says the request was accepted.
    func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current, options: [])
    }

    func unhide(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.unhide() ?? false
    }

    func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
