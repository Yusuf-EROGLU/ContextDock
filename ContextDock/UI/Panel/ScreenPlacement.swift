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

    /// Frame for a bar attached to `edge`, centered along that edge inside the visible area.
    /// `preferredLength` runs along the edge (width for top/bottom, height for left/right);
    /// `thickness` is the other dimension.
    static func barFrame(edge: BarEdge, preferredLength: CGFloat, thickness: CGFloat, margin: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let sideMargin: CGFloat = 12
        switch edge {
        case .bottom, .top:
            let width = min(preferredLength, visible.width - 2 * sideMargin)
            let x = visible.midX - width / 2
            let y = edge == .bottom ? visible.minY + margin : visible.maxY - margin - thickness
            return NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: thickness.rounded())
        case .left, .right:
            let height = min(preferredLength, visible.height - 2 * sideMargin)
            let y = visible.midY - height / 2
            let x = edge == .left ? visible.minX + margin : visible.maxX - margin - thickness
            return NSRect(x: x.rounded(), y: y.rounded(), width: thickness.rounded(), height: height.rounded())
        }
    }
}
