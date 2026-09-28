import Foundation
import Testing
@testable import ContextDock

@Suite("JSONStore", .serialized)
struct JSONStoreTests {
    private final class LockedValues: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt32] = []

        func append(_ value: UInt32) { lock.withLock { storage.append(value) } }
        var values: [UInt32] { lock.withLock { storage } }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    private enum StubError: Error { case failed }

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

    @Test("writer serializes queued saves and flushes the newest value last")
    func serializedWriter() throws {
        let written = LockedValues()
        let writer = PersistenceWriter<PersistedState> { state in
            if state.hotkey?.keyCode == 1 { Thread.sleep(forTimeInterval: 0.02) }
            written.append(state.hotkey?.keyCode ?? 0)
        }
        func state(_ keyCode: UInt32) -> PersistedState {
            var value = PersistedState()
            value.hotkey = HotkeyConfig(keyCode: keyCode, carbonModifiers: HotkeyConfig.commandKeyBit)
            return value
        }

        writer.save(state(1), revision: 1) { _ in }
        writer.save(state(2), revision: 2) { _ in }
        try writer.flush(state(3))

        #expect(written.values == [1, 2, 3])
    }

    @Test("flush result wins over a delayed completion for the same revision")
    @MainActor func flushSupersedesDelayedCompletion() async throws {
        let attempts = LockedCounter()
        let writer = PersistenceWriter<PersistedState> { _ in
            if attempts.increment() == 1 {
                Thread.sleep(forTimeInterval: 0.05)
                throw StubError.failed
            }
        }
        let service = PersistenceService(fileURL: temporaryFile(), writer: writer)
        service.update { $0.hotkey = .default }

        try await Task.sleep(for: .milliseconds(310))
        service.flush()
        await Task.yield()

        #expect(service.status == .ok)
    }
}
