import AppKit

/// Decides when an expanded bar should collapse: after the pointer has stayed away from the
/// panel for the configured delay, unless something interactive is open. Pure decision logic
/// lives in `AutoHidePolicy` so it can be unit tested.
struct AutoHidePolicy: Sendable {
    var delay: TimeInterval

    /// - Parameters:
    ///   - lastInside: last time the pointer was over the panel (or the bar was expanded).
    ///   - blocked: a drag, a context menu or a popup is active.
    func shouldCollapse(now: Date, lastInside: Date, blocked: Bool) -> Bool {
        guard !blocked else { return false }
        return now.timeIntervalSince(lastInside) >= delay
    }
}

@MainActor
final class AutoHideController {
    private let preferences: Preferences
    private let barState: BarState
    private weak var panel: NSWindow?
    private var loop: Task<Void, Never>?
    private var lastInside = Date()

    /// Extra blockers supplied by the composition root (popups, search panel…).
    var isBlocked: () -> Bool = { false }
    var onCollapse: () -> Void = {}

    init(preferences: Preferences, barState: BarState, panel: NSWindow) {
        self.preferences = preferences
        self.barState = barState
        self.panel = panel
    }

    func start() {
        guard loop == nil else { return }
        lastInside = Date()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Call when the bar was just expanded so the delay starts from now.
    func noteExpanded() {
        lastInside = Date()
    }

    private func tick() {
        guard preferences.autoHideEnabled, !barState.isCollapsed, let panel, panel.isVisible else {
            lastInside = Date()
            return
        }
        let now = Date()
        let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        let blocked = barState.drag != nil || barState.isMenuOpen || isBlocked()
        if inside || blocked {
            lastInside = now
            return
        }
        let policy = AutoHidePolicy(delay: preferences.autoHideDelay)
        if policy.shouldCollapse(now: now, lastInside: lastInside, blocked: blocked) {
            onCollapse()
        }
    }
}
