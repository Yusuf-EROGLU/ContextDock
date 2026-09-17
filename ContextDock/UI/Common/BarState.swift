import AppKit
import Observation

/// Transient UI state of the bar (hover, keyboard selection, toast, drag). Main actor only.
@MainActor
@Observable
final class BarState {
    var hoveredItem: BarItemID?
    var keyboardSelectedItem: BarItemID?
    var toast: Toast?
    var drag: DragState?
    /// Only the handle is visible; the cards are hidden until the handle is clicked or hovered.
    var isCollapsed = false
    /// A context menu is open; auto-hide must wait.
    var isMenuOpen = false

    struct Toast: Equatable {
        var message: String
        var isError: Bool
    }

    /// Where a dragged card would land.
    enum DropTarget: Equatable {
        /// Stack onto this item (creates or extends a group).
        case stack(BarItemID)
        /// Insert before this item (reorder); `nil` = end of the bar.
        case insert(before: BarItemID?)
        /// Pull a window out of its group.
        case detach
    }

    struct DragState: Equatable {
        var item: BarItemID
        /// Current pointer location in the bar view's (top-left origin) coordinates.
        var location: CGPoint
        var target: DropTarget?
        var fromGroup: GroupID?
    }

    private var toastTask: Task<Void, Never>?

    func showToast(_ message: String, isError: Bool = true, duration: Duration = .seconds(3)) {
        let new = Toast(message: message, isError: isError)
        if toast == new { return }
        toast = new
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
