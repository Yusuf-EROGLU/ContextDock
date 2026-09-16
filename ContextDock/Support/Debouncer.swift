import Foundation

/// Keyed debounce for actor-isolated work. Each `schedule` cancels the pending task for the
/// same key and starts a new delay; the action runs on the AX actor when the delay elapses.
@AXActor
final class Debouncer<Key: Hashable & Sendable> {
    private var pending: [Key: Task<Void, Never>] = [:]

    nonisolated init() {}

    func schedule(_ key: Key, after delay: Duration, action: @escaping @AXActor @Sendable () async -> Void) {
        pending[key]?.cancel()
        pending[key] = Task { @AXActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            pending[key] = nil
            await action()
        }
    }

    func cancel(_ key: Key) {
        pending[key]?.cancel()
        pending[key] = nil
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}
