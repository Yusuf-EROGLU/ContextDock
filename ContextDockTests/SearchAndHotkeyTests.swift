import Foundation
import Testing
@testable import ContextDock

@Suite("SearchMatcher")
struct SearchMatcherTests {
    private func candidate(_ order: Int, label: String, app: String = "Ghostty", title: String? = nil, project: String? = nil, branch: String? = nil) -> SearchCandidate {
        SearchCandidate(id: WindowSessionID(), order: order, label: label, applicationName: app, title: title, projectName: project, branch: branch)
    }

    @Test func emptyQueryKeepsBarOrder() {
        let c = [candidate(2, label: "B"), candidate(0, label: "A"), candidate(1, label: "C")]
        #expect(SearchMatcher.rank("", in: c).map(\.label) == ["A", "C", "B"])
    }

    @Test("label matches rank above title matches; diacritics and case are ignored")
    func weighting() {
        let c = [
            candidate(0, label: "Backend", title: "ses deneyi"),
            candidate(1, label: "Ses Deneyi", app: "Unity", project: "music-game-audio", branch: "feature/audio"),
        ]
        #expect(SearchMatcher.rank("ses", in: c).first?.label == "Ses Deneyi")
        #expect(SearchMatcher.rank("SES", in: c).first?.label == "Ses Deneyi")
        #expect(SearchMatcher.rank("audio", in: c).map(\.label) == ["Ses Deneyi"])
        #expect(SearchMatcher.rank("müzik", in: [candidate(0, label: "Muzik Oyunu")]).count == 1)
    }

    @Test func subsequenceFallback() {
        let c = [candidate(0, label: "music-game-audio")]
        #expect(SearchMatcher.rank("mga", in: c).count == 1)
        #expect(SearchMatcher.rank("xyz", in: c).isEmpty)
    }

    @Test func multipleTermsMustAllMatch() {
        let c = [candidate(0, label: "Backend", branch: "dev"), candidate(1, label: "Backend", branch: "main")]
        #expect(SearchMatcher.rank("backend main", in: c).count == 1)
    }
}

@Suite("HotkeyConfig")
struct HotkeyConfigTests {
    @Test func defaultIsControlOptionSpace() {
        #expect(HotkeyConfig.default.displayString == "⌃⌥Space")
        #expect(HotkeyConfig.default.hasModifier)
    }

    @Test func codableRoundTrip() throws {
        let config = HotkeyConfig(keyCode: 12, carbonModifiers: HotkeyConfig.commandKeyBit | HotkeyConfig.shiftKeyBit)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(HotkeyConfig.self, from: data) == config)
        #expect(config.displayString == "⇧⌘Q")
    }

    @Test func noModifierIsRejected() {
        #expect(!HotkeyConfig(keyCode: 0, carbonModifiers: 0).hasModifier)
    }
}

@Suite("Unity process arguments")
struct UnityProcessArgumentsTests {
    @Test func parsesProcArgsLayout() {
        var data = Data()
        var argc = Int32(3)
        data.append(Data(bytes: &argc, count: 4))
        data.append(Data("/Applications/Unity/Unity.app/Contents/MacOS/Unity\0\0\0".utf8))
        data.append(Data("/Applications/Unity/Unity.app/Contents/MacOS/Unity\0-projectPath\0/Users/me/Worktrees/music game\0ENV=1\0".utf8))
        let args = UnityProcessArgumentsAdapter.parseProcArgs(data)
        #expect(args == ["/Applications/Unity/Unity.app/Contents/MacOS/Unity", "-projectPath", "/Users/me/Worktrees/music game"])
        #expect(UnityProcessArgumentsAdapter.projectPath(in: args ?? []) == "/Users/me/Worktrees/music game")
    }

    @Test func projectPathVariants() {
        #expect(UnityProcessArgumentsAdapter.projectPath(in: ["Unity", "-projectpath=/p/x"]) == "/p/x")
        #expect(UnityProcessArgumentsAdapter.projectPath(in: ["Unity", "-projectPath"]) == nil)
        #expect(UnityProcessArgumentsAdapter.projectPath(in: ["Unity", "-batchmode"]) == nil)
    }

    @Test func readsOwnArguments() {
        let args = UnityProcessArgumentsAdapter.arguments(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(args?.isEmpty == false)
    }

    @Test func unityProjectValidation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cdock-unity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        #expect(ProjectFolderValidator.validate(base) == .folder(warning: nil))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("ProjectSettings"), withIntermediateDirectories: true)
        #expect(ProjectFolderValidator.validate(base) == .unityProject)
        #expect(ProjectFolderValidator.validate(base.appendingPathComponent("missing")) == .unreadable)
    }
}
