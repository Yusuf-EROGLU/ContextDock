import AppKit

/// Entry point. The app is a menu-bar accessory (`LSUIElement`), so there is no SwiftUI `App`
/// scene; AppKit owns the lifecycle and SwiftUI is used for views hosted in panels/windows.
@main
@MainActor
enum ContextDockMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
