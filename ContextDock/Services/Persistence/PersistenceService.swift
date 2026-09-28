import Foundation
import Observation

/// Performs every state-file write on one serial queue. A synchronous flush is ordered after
/// any write already in flight, so an older debounced snapshot can never land after the state
/// written during termination.
final class PersistenceWriter<Value: Codable & Sendable>: Sendable {
    enum SaveResult: Sendable {
        case success(revision: UInt64)
        case failure(revision: UInt64, message: String)
    }

    private let queue = DispatchQueue(label: "com.yusuferoglu.ContextDock.persistence", qos: .utility)
    private let write: @Sendable (Value) throws -> Void

    init(store: JSONStore<Value>) {
        write = { value in try store.save(value) }
    }

    init(write: @escaping @Sendable (Value) throws -> Void) {
        self.write = write
    }

    func save(_ value: Value, revision: UInt64, completion: @escaping @Sendable (SaveResult) -> Void) {
        queue.async { [write] in
            do {
                try write(value)
                completion(.success(revision: revision))
            } catch {
                completion(.failure(revision: revision, message: error.localizedDescription))
            }
        }
    }

    func flush(_ value: Value) throws {
        try queue.sync { try write(value) }
    }
}

/// Everything ContextDock persists as JSON (simple preferences live in UserDefaults):
/// the shortcut, and the remembered windows/groups that are re-attached after a relaunch.
struct PersistedState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = PersistedState.currentSchemaVersion
    var hotkey: HotkeyConfig?
    var windows: [PersistedWindow] = []
    var groups: [PersistedGroup] = []

    enum CodingKeys: String, CodingKey { case schemaVersion, hotkey, windows, groups }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? PersistedState.currentSchemaVersion
        hotkey = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey)
        windows = try container.decodeIfPresent([PersistedWindow].self, forKey: .windows) ?? []
        groups = try container.decodeIfPresent([PersistedGroup].self, forKey: .groups) ?? []
    }
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
    private let writer: PersistenceWriter<PersistedState>
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var latestCompletedRevision: UInt64 = 0

    private(set) var state = PersistedState()
    private(set) var status: PersistenceStatus = .ok
    private(set) var isReadOnly = false

    init(
        fileURL: URL = PersistenceService.applicationSupportDirectory.appendingPathComponent("state.json"),
        writer injectedWriter: PersistenceWriter<PersistedState>? = nil
    ) {
        let store = JSONStore<PersistedState>(url: fileURL, currentSchemaVersion: PersistedState.currentSchemaVersion)
        self.store = store
        writer = injectedWriter ?? PersistenceWriter(store: store)
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
        revision &+= 1
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isReadOnly else { return }
        saveTask?.cancel()
        let snapshot = state
        let revision = self.revision
        let writer = self.writer
        let reportResult: @MainActor @Sendable (PersistenceWriter<PersistedState>.SaveResult) -> Void = { [weak self] result in
            self?.handleSaveResult(result)
        }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            writer.save(snapshot, revision: revision) { result in
                Task { @MainActor in
                    reportResult(result)
                }
            }
        }
    }

    private func handleSaveResult(_ result: PersistenceWriter<PersistedState>.SaveResult) {
        let completedRevision: UInt64
        switch result {
        case .success(let revision), .failure(let revision, _):
            completedRevision = revision
        }
        // A synchronous flush may already have committed this same revision after waiting for
        // the queued save. Its delayed completion must not change the post-flush status.
        guard completedRevision > latestCompletedRevision else { return }
        latestCompletedRevision = completedRevision

        switch result {
        case .success:
            if case .saveFailed = status { status = .ok }
        case .failure(_, let message):
            status = .saveFailed(message)
            Log.store.error("Save failed: \(message, privacy: .public)")
        }
    }

    /// Flushes any pending save synchronously (used at quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !isReadOnly else { return }
        do {
            try writer.flush(state)
            latestCompletedRevision = revision
            if case .saveFailed = status { status = .ok }
        } catch {
            Log.store.error("Flush failed: \(error.localizedDescription, privacy: .public)")
            status = .saveFailed(error.localizedDescription)
        }
    }
}
