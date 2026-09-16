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

    static var isRunningAsTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestSessionIdentifier"] != nil || env["XCTestBundlePath"] != nil || env["XCTestConfigurationFilePath"] != nil
    }
}
