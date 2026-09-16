import Foundation
import Observation

/// Everything ContextDock persists as JSON (simple preferences live in UserDefaults). Window
/// names, badges and groups are session-only by design and never stored here.
struct PersistedState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = PersistedState.currentSchemaVersion
    var hotkey: HotkeyConfig?
}

/// User-visible status of the persistence layer.
enum PersistenceStatus: Sendable, Equatable {
    case ok
    case corruptFilePreserved(URL?)
    case readOnlyNewerSchema(found: Int)
    case saveFailed(String)
}

/// Owns the persisted state file, loads it defensively and saves it atomically (debounced).
@MainActor
@Observable
final class PersistenceService {
    nonisolated static let applicationSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ContextDock", isDirectory: true)
    }()

    private let store: JSONStore<PersistedState>
    private var saveTask: Task<Void, Never>?

    private(set) var state = PersistedState()
    private(set) var status: PersistenceStatus = .ok
    private(set) var isReadOnly = false

    init(fileURL: URL = PersistenceService.applicationSupportDirectory.appendingPathComponent("state.json")) {
        store = JSONStore(url: fileURL, currentSchemaVersion: PersistedState.currentSchemaVersion)
        load()
    }

    func load() {
        switch store.load() {
        case .loaded(let loaded):
            state = loaded
            status = .ok
            isReadOnly = false
        case .missing:
            state = PersistedState()
            status = .ok
            isReadOnly = false
        case .corrupt(let preserved):
            state = PersistedState()
            status = .corruptFilePreserved(preserved)
            isReadOnly = false
        case .newerSchema(let found):
            state = PersistedState()
            status = .readOnlyNewerSchema(found: found)
            isReadOnly = true
        }
    }

    func update(_ mutate: (inout PersistedState) -> Void) {
        var copy = state
        mutate(&copy)
        copy.schemaVersion = PersistedState.currentSchemaVersion
        guard copy != state else { return }
        state = copy
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isReadOnly else { return }
        saveTask?.cancel()
        let snapshot = state
        let store = self.store
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try store.save(snapshot)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            if case .failure(let error) = result {
                self?.status = .saveFailed(error.localizedDescription)
                Log.store.error("Save failed: \(error.localizedDescription, privacy: .public)")
            } else if case .saveFailed = self?.status {
                self?.status = .ok
            }
        }
    }

    /// Flushes any pending save synchronously (used at quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !isReadOnly else { return }
        do {
            try store.save(state)
        } catch {
            Log.store.error("Flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
