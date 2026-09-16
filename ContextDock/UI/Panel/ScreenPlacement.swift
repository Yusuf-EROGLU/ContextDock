import AppKit

/// Chooses the screen for the bar and falls back to a visible one when the preferred screen
/// is gone (for example after unplugging an external display).
enum ScreenPlacement {
    static func resolve(_ selection: ScreenSelection) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        switch selection {
        case .primary:
            return screens.first
        case .mainWindowScreen:
            return NSScreen.main ?? screens.first
        case .mouseScreen:
            let mouse = NSEvent.mouseLocation
            return screens.first { $0.frame.contains(mouse) } ?? screens.first
        case .display(let id):
            return screens.first { displayID(of: $0) == id } ?? screens.first
        }
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Bottom-centered frame inside the screen's visible area.
    static func barFrame(preferredWidth: CGFloat, height: CGFloat, bottomMargin: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let sideMargin: CGFloat = 12
        let width = min(preferredWidth, visible.width - 2 * sideMargin)
        let x = visible.midX - width / 2
        let y = visible.minY + bottomMargin
        return NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }
}
