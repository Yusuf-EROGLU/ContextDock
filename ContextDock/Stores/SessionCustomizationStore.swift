import Foundation

/// In-memory, session-only customizations keyed by window session id. Entries die with the
/// window (on confirmed removal) or with ContextDock.
@MainActor
final class SessionCustomizationStore {
    private var entries: [WindowSessionID: SessionCustomization] = [:]

    init() {}

    subscript(id: WindowSessionID) -> SessionCustomization? {
        entries[id]
    }

    func update(_ id: WindowSessionID, _ mutate: (inout SessionCustomization) -> Void) {
        var value = entries[id] ?? SessionCustomization()
        mutate(&value)
        entries[id] = value.isEmpty ? nil : value
    }

    func reset(_ id: WindowSessionID) {
        entries[id] = nil
    }

    func resetAll() {
        entries.removeAll()
    }

    /// Drops entries whose windows are no longer tracked.
    func purge(keeping live: Set<WindowSessionID>) {
        for id in entries.keys where !live.contains(id) {
            entries[id] = nil
        }
    }

    var all: [WindowSessionID: SessionCustomization] { entries }
}
