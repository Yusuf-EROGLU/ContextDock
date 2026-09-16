import AppKit
import Observation

/// Transient UI state of the bar (hover, keyboard selection, toast). Main actor only.
@MainActor
@Observable
final class BarState {
    var hoveredCard: WindowSessionID?
    var keyboardSelectedCard: WindowSessionID?
    var toast: Toast?

    struct Toast: Equatable {
        var message: String
        var isError: Bool
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
