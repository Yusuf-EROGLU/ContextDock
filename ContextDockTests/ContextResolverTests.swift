import Foundation
import Testing
@testable import ContextDock

@Suite("ContextResolver")
struct ContextResolverTests {
    private let manual = ProjectBinding(projectPath: "/p/main", scope: .window, validation: .unityProject, boundAt: Date())
    private let bridge = UnityBridgeReport(pid: 1, processStartedAtUnixMs: 0, editorSessionId: "s", projectPath: "/p/audio", projectName: "audio", unityVersion: nil, updatedAtUnixMs: 0)
    private let args = ProcessArgumentsHint(projectPath: "/p/args", validation: .unityProject)

    @Test("manual binding wins and flags conflicts")
    func manualWins() {
        let ctx = ContextResolver.resolve(ContextInputs(manual: manual, bridge: bridge, processArguments: args, rawTitle: "t"))
        #expect(ctx.contextSource == .manual)
        #expect(ctx.confidence == .userConfirmed)
        #expect(ctx.projectPath == "/p/main")
        #expect(ctx.conflictNote?.contains("audio") == true)
    }

    @Test("bridge beats process arguments, which beat structured title")
    func priorityChain() {
        let withBridge = ContextResolver.resolve(ContextInputs(bridge: bridge, processArguments: args, structuredTitle: StructuredTitle(label: "L", project: nil, branch: nil)))
        #expect(withBridge.contextSource == .unityBridge)
        #expect(withBridge.projectPath == "/p/audio")
        #expect(withBridge.confidence == .verified)

        let withArgs = ContextResolver.resolve(ContextInputs(processArguments: args, structuredTitle: StructuredTitle(label: "L", project: nil, branch: nil)))
        #expect(withArgs.contextSource == .processArguments)
        #expect(withArgs.projectPath == "/p/args")

        let structured = ContextResolver.resolve(ContextInputs(structuredTitle: StructuredTitle(label: "Backend", project: "backend", branch: "dev"), rawTitle: "x"))
        #expect(structured.contextSource == .structuredTitle)
        #expect(structured.confidence == .inferred)
        #expect(structured.projectPath == nil, "structured titles never provide a path")
        #expect(structured.structuredLabel == "Backend")
        #expect(structured.branchName == "dev")

        let title = ContextResolver.resolve(ContextInputs(rawTitle: "just a title"))
        #expect(title.contextSource == .windowTitle)
        #expect(title.confidence == .unknown)
    }

    @Test("unvalidated process arguments are ignored")
    func unvalidatedArgs() {
        let ctx = ContextResolver.resolve(ContextInputs(processArguments: ProcessArgumentsHint(projectPath: "/nope", validation: .unreadable)))
        #expect(ctx.contextSource == .none)
        #expect(ctx.projectPath == nil)
    }

    @Test("git info is attached only to trusted paths")
    func gitAttachment() {
        let git = GitInfo(worktreeRoot: "/p/main", repositoryRoot: "/p/main", gitDirectory: nil, commonDirectory: nil, branchName: "main", shortCommit: "abc1234", isDetached: false, isUnborn: false, status: .ok, lastUpdatedAt: Date(), isStale: false)
        let trusted = ContextResolver.resolve(ContextInputs(manual: manual, git: git))
        #expect(trusted.branchName == "main")
        #expect(trusted.gitStatus == .ok)

        let structured = ContextResolver.resolve(ContextInputs(structuredTitle: StructuredTitle(label: "L", project: nil, branch: "x"), git: git))
        #expect(structured.gitStatus == nil)
        #expect(structured.branchName == "x")
    }

    @Test("stale bridge marks the context stale")
    func staleBridge() {
        let ctx = ContextResolver.resolve(ContextInputs(bridge: bridge, bridgeIsStale: true))
        #expect(ctx.isStale)
    }
}

@Suite("PathNormalizer and ContextKey")
struct PathNormalizerTests {
    @Test func trailingSlashAndCase() {
        #expect(PathNormalizer.normalize("/Users/Me/Proj/") == "/Users/Me/Proj")
        #expect(PathNormalizer.normalize("/Users/Me//Proj/./x/..") == "/Users/Me/Proj")
        #expect(PathNormalizer.normalize("/") == "/")
    }

    @Test("NFC and NFD spellings of the same path compare equal")
    func unicodeEquality() {
        let nfc = "/tmp/Müzik Oyunu"
        let nfd = "/tmp/Mu\u{0308}zik Oyunu"
        #expect(ContextKey(applicationKind: .unityEditor, projectPath: nfc) == ContextKey(applicationKind: .unityEditor, projectPath: nfd))
    }

    @Test("symlinks resolve to the same key")
    func symlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cdock-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real dir")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ContextKey(applicationKind: .ghostty, projectPath: link.path) == ContextKey(applicationKind: .ghostty, projectPath: real.path))
        #expect(ContextKey(applicationKind: .ghostty, projectPath: real.path) != ContextKey(applicationKind: .unityEditor, projectPath: real.path))
    }
}

@Suite("StructuredTitleParser")
struct StructuredTitleParserTests {
    @Test func parsesFields() {
        let parsed = StructuredTitleParser.parse("CDOCK:v1|label=Backend|project=backend|branch=feature%2Fauth")
        #expect(parsed == StructuredTitle(label: "Backend", project: "backend", branch: "feature/auth"))
    }

    @Test func rejectsOtherVersionsAndPlainTitles() {
        #expect(StructuredTitleParser.parse("CDOCK:v2|label=x") == nil)
        #expect(StructuredTitleParser.parse("zsh — 80x24") == nil)
        #expect(StructuredTitleParser.parse("CDOCK:v1|") == nil)
    }

    @Test func rejectsControlCharactersAndOversizedValues() {
        #expect(StructuredTitleParser.parse("CDOCK:v1|label=bad%1Bvalue") == nil)
        #expect(StructuredTitleParser.parse("CDOCK:v1|label=line%0Abreak") == nil)
        let long = String(repeating: "a", count: 200)
        #expect(StructuredTitleParser.parse("CDOCK:v1|label=\(long)") == nil)
    }

    @Test func ignoresUnknownKeysAndEmptyValues() {
        let parsed = StructuredTitleParser.parse("CDOCK:v1|foo=bar|label=%20|project=api")
        #expect(parsed == StructuredTitle(label: nil, project: "api", branch: nil))
    }
}
