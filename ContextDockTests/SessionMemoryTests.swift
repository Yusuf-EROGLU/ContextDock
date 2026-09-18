import Foundation
import Testing
@testable import ContextDock

@Suite("FingerprintMatcher")
struct FingerprintMatcherTests {
    private func record(_ app: String, title: String?, pid: pid_t? = nil, start: Int64? = nil, bundle: String? = nil) -> PersistedWindow {
        PersistedWindow(id: UUID(), fingerprint: WindowFingerprint(bundleIdentifier: bundle ?? "com.\(app)", applicationName: app, title: title, pid: pid, processStartUnixMs: start), customization: SessionCustomization(name: title))
    }

    private func candidate(_ app: String, title: String?, order: UInt64, pid: pid_t = 1, start: Int64? = 1, bundle: String? = nil) -> FingerprintMatcher.Candidate {
        FingerprintMatcher.Candidate(id: WindowSessionID(), fingerprint: WindowFingerprint(bundleIdentifier: bundle ?? "com.\(app)", applicationName: app, title: title, pid: pid, processStartUnixMs: start), order: order)
    }

    @Test("exact title wins over order; single window of an app matches by app alone")
    func titleThenSingle() {
        let unity = record("unity", title: "music-game - Unity")
        let ghostty = record("ghostty", title: "old title")
        let cUnity = candidate("unity", title: "music-game - Unity", order: 2)
        let cOther = candidate("unity", title: "other - Unity", order: 1)
        let cGhostty = candidate("ghostty", title: "brand new title", order: 3)
        let matches = FingerprintMatcher.match(pending: [unity, ghostty], candidates: [cOther, cUnity, cGhostty])
        #expect(matches[unity.id] == cUnity.id)
        #expect(matches[ghostty.id] == cGhostty.id, "only Ghostty window: matched despite the changed title")
    }

    @Test("same process instance beats a same-title window of another instance")
    func processInstanceFirst() {
        let rec = record("ghostty", title: "zsh", pid: 500, start: 1_000)
        let sameProcess = candidate("ghostty", title: "zsh", order: 2, pid: 500, start: 1_000)
        let otherProcess = candidate("ghostty", title: "zsh", order: 1, pid: 600, start: 2_000)
        let matches = FingerprintMatcher.match(pending: [rec], candidates: [otherProcess, sameProcess])
        #expect(matches[rec.id] == sameProcess.id)
    }

    @Test("remaining windows of an app pair up in order, never across apps")
    func orderFallback() {
        let a = record("ghostty", title: "a"), b = record("ghostty", title: "b")
        let x = candidate("ghostty", title: "x", order: 1), y = candidate("ghostty", title: "y", order: 2)
        let z = candidate("rider", title: "a", order: 0)
        let matches = FingerprintMatcher.match(pending: [a, b], candidates: [z, y, x])
        #expect(matches[a.id] == x.id)
        #expect(matches[b.id] == y.id)
        #expect(!matches.values.contains(z.id))
    }

    @Test("a candidate is used at most once")
    func noDoubleUse() {
        let a = record("unity", title: "P"), b = record("unity", title: "P")
        let only = candidate("unity", title: "P", order: 1)
        let matches = FingerprintMatcher.match(pending: [a, b], candidates: [only])
        #expect(matches.count == 1)
    }
}

@Suite("SessionMemory")
@MainActor
struct SessionMemoryTests {
    private func makeStore(state: PersistedState? = nil) -> (WindowStore, PersistenceService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdock-memory-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("state.json")
        if let state {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONStore<PersistedState>(url: url, currentSchemaVersion: 1).save(state)
        }
        let persistence = PersistenceService(fileURL: url)
        let store = WindowStore(customizations: SessionCustomizationStore(), persistence: persistence, apps: RunningAppsProvider())
        return (store, persistence, dir)
    }

    private func snapshot(_ entries: [(ProcessSnapshot, [WindowSnapshot])]) -> DiscoverySnapshot {
        var processes: [ProcessInstanceKey: ProcessSnapshot] = [:]
        var windows: [WindowSnapshot] = []
        for (process, ws) in entries {
            processes[process.key] = process
            windows.append(contentsOf: ws)
        }
        return DiscoverySnapshot(processes: processes, windows: windows, permission: .granted, generatedAt: Date())
    }

    @Test("names and groups are saved, then restored onto matching windows after a relaunch")
    func roundTrip() throws {
        let (store, persistence, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unity = ProcessSnapshot.test(key: .test(pid: 10, start: 1), kind: .unityEditor, name: "Unity")
        let ghostty = ProcessSnapshot.test(key: .test(pid: 20, start: 2), kind: .ghostty, name: "Ghostty")
        let u = WindowSnapshot.test(process: unity.key, sequence: 1, title: "Game - Unity")
        let g1 = WindowSnapshot.test(process: ghostty.key, sequence: 2, title: "backend")
        let g2 = WindowSnapshot.test(process: ghostty.key, sequence: 3, title: "tests")
        store.apply(snapshot([(unity, [u]), (ghostty, [g1, g2])]))
        let memory = SessionMemory(store: store, persistence: persistence)
        store.onItemsChanged = { memory.sync() }
        memory.sync()

        store.rename(g2.id, to: "Test terminal")
        store.stack(.window(g1.id), onto: .window(u.id))
        store.renameGroup(store.group(containing: u.id)!.id, to: "Audio task")
        persistence.flush()

        // Relaunch: new window identities, Ghostty titles changed, Unity title identical.
        let (store2, persistence2, _) = { () -> (WindowStore, PersistenceService, URL) in
            let p = PersistenceService(fileURL: dir.appendingPathComponent("state.json"))
            let s = WindowStore(customizations: SessionCustomizationStore(), persistence: p, apps: RunningAppsProvider())
            return (s, p, dir)
        }()
        #expect(persistence2.state.windows.count == 3)
        #expect(persistence2.state.groups.count == 1)
        let memory2 = SessionMemory(store: store2, persistence: persistence2)
        store2.onItemsChanged = { memory2.sync() }
        let unity2 = ProcessSnapshot.test(key: .test(pid: 11, start: 5), kind: .unityEditor, name: "Unity")
        let ghostty2 = ProcessSnapshot.test(key: .test(pid: 21, start: 6), kind: .ghostty, name: "Ghostty")
        let u2 = WindowSnapshot.test(process: unity2.key, sequence: 1, title: "Game - Unity")
        let g1b = WindowSnapshot.test(process: ghostty2.key, sequence: 2, title: "backend")
        let g2b = WindowSnapshot.test(process: ghostty2.key, sequence: 3, title: "something else")
        store2.apply(snapshot([(unity2, [u2]), (ghostty2, [g1b, g2b])]))
        memory2.sync()

        let group = try #require(store2.group(containing: u2.id))
        #expect(group.name == "Audio task")
        #expect(Set(group.members) == [u2.id, g1b.id])
        #expect(store2.card(for: g2b.id)?.title == "Test terminal", "single remaining Ghostty window inherits the name")
    }

    @Test("closing a member while running drops it from the remembered group; shutdown does not")
    func closeVersusShutdown() throws {
        let (store, persistence, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unity = ProcessSnapshot.test(key: .test(pid: 10, start: 1), kind: .unityEditor, name: "Unity")
        let ghostty = ProcessSnapshot.test(key: .test(pid: 20, start: 2), kind: .ghostty, name: "Ghostty")
        let u = WindowSnapshot.test(process: unity.key, sequence: 1, title: "U")
        let g = WindowSnapshot.test(process: ghostty.key, sequence: 2, title: "G")
        store.apply(snapshot([(unity, [u]), (ghostty, [g])]))
        let memory = SessionMemory(store: store, persistence: persistence)
        store.onItemsChanged = { memory.sync() }
        memory.sync()
        store.stack(.window(g.id), onto: .window(u.id))
        #expect(persistence.state.groups.count == 1)

        // User closes the Ghostty window: the group dissolves on screen; the record is kept for
        // the grace period (an app may re-create its window) and then dropped.
        store.apply(snapshot([(unity, [u])]))
        memory.sync()
        #expect(store.group(containing: u.id) == nil)
        #expect(persistence.state.groups.count == 1, "still remembered during the grace period")
        memory.lostGrace = 0
        memory.sync()
        #expect(persistence.state.groups.isEmpty)
        memory.lostGrace = 120

        // Rebuild the group, then simulate shutdown: windows vanish but the file keeps the group.
        let g2 = WindowSnapshot.test(process: ghostty.key, sequence: 3, title: "G")
        store.apply(snapshot([(unity, [u]), (ghostty, [g2])]))
        memory.sync()
        store.stack(.window(g2.id), onto: .window(u.id))
        #expect(persistence.state.groups.count == 1)
        memory.freeze()
        store.apply(snapshot([]))
        memory.sync()
        #expect(persistence.state.groups.count == 1)
        #expect(persistence.state.windows.count == 2)
    }

    @Test("a window re-created by its app within the grace period gets its name and group back")
    func lostAndRecreated() throws {
        let (store, persistence, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unity = ProcessSnapshot.test(key: .test(pid: 10, start: 1), kind: .unityEditor, name: "Unity")
        let ghostty = ProcessSnapshot.test(key: .test(pid: 20, start: 2), kind: .ghostty, name: "Ghostty")
        let u = WindowSnapshot.test(process: unity.key, sequence: 1, title: "U")
        let g = WindowSnapshot.test(process: ghostty.key, sequence: 2, title: "backend")
        store.apply(snapshot([(unity, [u]), (ghostty, [g])]))
        let memory = SessionMemory(store: store, persistence: persistence)
        store.onItemsChanged = { memory.sync() }
        memory.sync()
        store.rename(g.id, to: "Backend")
        let groupID = store.stack(.window(g.id), onto: .window(u.id))!

        // Ghostty drops the window and brings back a new one with the same title.
        store.apply(snapshot([(unity, [u])]))
        memory.sync()
        #expect(store.group(groupID) == nil)
        let g2 = WindowSnapshot.test(process: ghostty.key, sequence: 3, title: "backend")
        store.apply(snapshot([(unity, [u]), (ghostty, [g2])]))
        memory.sync()
        let restored = try #require(store.group(containing: u.id))
        #expect(restored.id == groupID)
        #expect(Set(restored.members) == [u.id, g2.id])
        #expect(store.card(for: g2.id)?.title == "Backend")
    }

    @Test("records not matched within the restore window are dropped")
    func restoreWindowExpiry() {
        var state = PersistedState()
        state.windows = [PersistedWindow(id: UUID(), fingerprint: WindowFingerprint(bundleIdentifier: "x", applicationName: "X", title: "t", pid: nil, processStartUnixMs: nil), customization: SessionCustomization(name: "n"))]
        let (store, persistence, dir) = makeStore(state: state)
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = SessionMemory(store: store, persistence: persistence)
        memory.restoreWindow = 0
        store.apply(snapshot([]))
        memory.sync()
        #expect(memory.pendingCount == 0)
        #expect(persistence.state.windows.isEmpty)
    }
}
