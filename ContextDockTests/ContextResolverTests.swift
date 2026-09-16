import Foundation
import Testing
@testable import ContextDock

@Suite("ContextResolver")
struct ContextResolverTests {
    private let bridge = UnityBridgeReport(pid: 1, processStartedAtUnixMs: 0, editorSessionId: "s", projectPath: "/p/audio/", projectName: "audio", unityVersion: nil, updatedAtUnixMs: 0)

    @Test("bridge beats structured title, which beats the plain title")
    func priorityChain() {
        let withBridge = ContextResolver.resolve(ContextInputs(bridge: bridge, structuredTitle: StructuredTitle(label: "L", project: nil, branch: nil)))
        #expect(withBridge.contextSource == .unityBridge)
        #expect(withBridge.projectPath == "/p/audio")
        #expect(withBridge.projectDisplayName == "audio")
        #expect(withBridge.confidence == .verified)

        let structured = ContextResolver.resolve(ContextInputs(structuredTitle: StructuredTitle(label: "Backend", project: "backend", branch: "dev"), rawTitle: "x"))
        #expect(structured.contextSource == .structuredTitle)
        #expect(structured.confidence == .inferred)
        #expect(structured.projectPath == nil, "structured titles never provide a path")
        #expect(structured.structuredLabel == "Backend")
        #expect(structured.branchName == "dev")

        let title = ContextResolver.resolve(ContextInputs(rawTitle: "just a title"))
        #expect(title.contextSource == .windowTitle)
        #expect(title.confidence == .unknown)

        let nothing = ContextResolver.resolve(ContextInputs())
        #expect(nothing.contextSource == .none)
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
