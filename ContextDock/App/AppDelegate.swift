import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningAsTestHost {
            Log.app.info("Running as XCTest host; UI and AX worker disabled")
            return
        }
        let services = AppServices()
        self.services = services
        services.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// True when the app was launched as the host of an XCTest/Swift Testing run. The exact
    /// environment variables differ between Xcode versions, so several signals are checked:
    /// XCTest-prefixed variables, the test bundle injection library, and the presence of the
    /// XCTest runtime in the process.
    nonisolated static var isRunningAsTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        if env.keys.contains(where: { $0.hasPrefix("XCTest") || $0.hasPrefix("SWT_") }) { return true }
        if let inserted = env["DYLD_INSERT_LIBRARIES"], inserted.contains("XCTest") || inserted.contains("Testing") { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        return false
    }
}
