import Foundation
import Testing
@testable import ContextDock

@Suite("JSONStore", .serialized)
struct JSONStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cdock-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    @Test("round trip and atomic write leave no temporary files")
    func roundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONStore<PersistedState>(url: url, currentSchemaVersion: PersistedState.currentSchemaVersion)
        var state = PersistedState()
        state.hotkey = HotkeyConfig(keyCode: 12, carbonModifiers: HotkeyConfig.commandKeyBit | HotkeyConfig.shiftKeyBit)
        try store.save(state)
        try store.save(state)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected loaded"); return }
        #expect(loaded.hotkey == state.hotkey)
        #expect(loaded.schemaVersion == PersistedState.currentSchemaVersion)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["state.json"])
    }

    @Test("missing file loads as missing")
    func missing() {
        let store = JSONStore<PersistedState>(url: temporaryFile(), currentSchemaVersion: 1)
        guard case .missing = store.load() else { Issue.record("expected missing"); return }
    }

    @Test("corrupt file is preserved and defaults are used")
    func corrupt() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = JSONStore<PersistedState>(url: url, currentSchemaVersion: 1)
        guard case .corrupt(let preserved) = store.load() else { Issue.record("expected corrupt"); return }
        #expect(preserved != nil)
        #expect(preserved?.lastPathComponent.hasPrefix("state.json.corrupt-") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: preserved!.path))
    }

    @Test("newer schema is reported and never overwritten")
    func newerSchema() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion": 99, "future": true}"#.utf8)
        try original.write(to: url)
        let store = JSONStore<PersistedState>(url: url, currentSchemaVersion: 1)
        guard case .newerSchema(let found) = store.load() else { Issue.record("expected newerSchema"); return }
        #expect(found == 99)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("PersistenceService enters read-only mode for newer schemas")
    @MainActor func serviceReadOnly() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion": 42}"#.utf8)
        try original.write(to: url)
        let service = PersistenceService(fileURL: url)
        #expect(service.isReadOnly)
        #expect(service.status == .readOnlyNewerSchema(found: 42))
        service.update { $0.hotkey = HotkeyConfig.default }
        service.flush()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("PersistenceService starts with defaults after a corrupt file")
    @MainActor func serviceCorrupt() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        let service = PersistenceService(fileURL: url)
        #expect(service.state == PersistedState())
        if case .corruptFilePreserved = service.status {} else { Issue.record("expected corrupt status") }
        #expect(!service.isReadOnly)
    }
}
