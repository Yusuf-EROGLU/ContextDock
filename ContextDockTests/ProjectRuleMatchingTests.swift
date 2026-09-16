import Foundation
import Testing
@testable import ContextDock

@Suite("Project rules in WindowStore")
@MainActor
struct ProjectRuleMatchingTests {
    private func makeStore() -> (WindowStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdock-rules-\(UUID().uuidString)", isDirectory: true)
        let persistence = PersistenceService(fileURL: dir.appendingPathComponent("state.json"))
        let store = WindowStore(customizations: SessionCustomizationStore(), persistence: persistence, apps: RunningAppsProvider())
        return (store, dir)
    }

    private func snapshot(windows: [WindowSnapshot], process: ProcessSnapshot) -> DiscoverySnapshot {
        DiscoverySnapshot(processes: [process.key: process], windows: windows, permission: .granted, generatedAt: Date())
    }

    @Test("a rule applies only after the window is verified to belong to the project")
    func ruleNeedsVerification() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = ProcessSnapshot.test(kind: .unityEditor, name: "Unity")
        let a = WindowSnapshot.test(process: process.key, sequence: 1, title: "music-game-audio - Unity")
        let b = WindowSnapshot.test(process: process.key, sequence: 2, title: "music-game-audio - Unity")
        store.apply(snapshot(windows: [a, b], process: process))

        let project = dir.appendingPathComponent("Müzik Oyunu", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.upsertRule(kind: .unityEditor, projectPath: project.path) { $0.customLabel = "Ses Deneyi"; $0.badge = .emoji("🧪") }

        #expect(store.card(for: a.id)?.title == "music-game-audio - Unity", "title similarity never triggers a rule")

        store.bindProject(a.id, binding: ProjectBinding(projectPath: project.path + "/", scope: .window, validation: .folder(warning: nil), boundAt: Date()))
        #expect(store.card(for: a.id)?.title == "Ses Deneyi")
        #expect(store.card(for: a.id)?.badge == .emoji("🧪"))
        #expect(store.card(for: b.id)?.title == "music-game-audio - Unity", "the sibling window is untouched")
        #expect(store.cards.count == 2, "two windows under the same rule stay two cards")
    }

    @Test("window custom name beats the project rule")
    func windowNameWins() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = ProcessSnapshot.test(kind: .unityEditor, name: "Unity")
        let a = WindowSnapshot.test(process: process.key, title: "T")
        store.apply(snapshot(windows: [a], process: process))
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.upsertRule(kind: .unityEditor, projectPath: project.path) { $0.customLabel = "Rule" }
        store.bindProject(a.id, binding: ProjectBinding(projectPath: project.path, scope: .window, validation: .folder(warning: nil), boundAt: Date()))
        store.rename(a.id, to: "Mine")
        #expect(store.card(for: a.id)?.title == "Mine")
        store.rename(a.id, to: nil)
        #expect(store.card(for: a.id)?.title == "Rule")
    }

    @Test("rules for a different application kind do not match")
    func kindMismatch() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = ProcessSnapshot.test(kind: .ghostty)
        let a = WindowSnapshot.test(process: process.key, title: "zsh")
        store.apply(snapshot(windows: [a], process: process))
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.upsertRule(kind: .unityEditor, projectPath: project.path) { $0.customLabel = "Unity rule" }
        store.bindProject(a.id, binding: ProjectBinding(projectPath: project.path, scope: .window, validation: .folder(warning: nil), boundAt: Date()))
        #expect(store.card(for: a.id)?.title == "proj")
    }

    @Test("session customizations are purged when the window disappears and never migrate")
    func purgeOnRemoval() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = ProcessSnapshot.test()
        let a = WindowSnapshot.test(process: process.key, sequence: 1, title: "Same")
        store.apply(snapshot(windows: [a], process: process))
        store.rename(a.id, to: "Custom")
        #expect(store.card(for: a.id)?.title == "Custom")

        // Same pid, new start time = new process instance with a window of the same title.
        let reused = ProcessSnapshot.test(key: .test(pid: process.key.pid, start: 99_999))
        let b = WindowSnapshot.test(process: reused.key, sequence: 2, title: "Same")
        store.apply(snapshot(windows: [b], process: reused))
        #expect(store.cards.count == 1)
        #expect(store.card(for: b.id)?.title == "Same")
        #expect(store.customizations[a.id] == nil)
    }

    @Test("process-instance scope binds all windows of that instance")
    func processScope() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unity = ProcessSnapshot.test(kind: .unityEditor, name: "Unity")
        let other = ProcessSnapshot.test(key: .test(pid: 200), kind: .unityEditor, name: "Unity")
        let a = WindowSnapshot.test(process: unity.key, sequence: 1, title: "A")
        let b = WindowSnapshot.test(process: unity.key, sequence: 2, title: "B")
        let c = WindowSnapshot.test(process: other.key, sequence: 3, title: "C")
        store.apply(DiscoverySnapshot(processes: [unity.key: unity, other.key: other], windows: [a, b, c], permission: .granted, generatedAt: Date()))
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.bindProject(a.id, binding: ProjectBinding(projectPath: project.path, scope: .processInstance, validation: .unityProject, boundAt: Date()))
        #expect(store.card(for: a.id)?.projectPath != nil)
        #expect(store.card(for: b.id)?.projectPath != nil)
        #expect(store.card(for: c.id)?.projectPath == nil)
    }
}
