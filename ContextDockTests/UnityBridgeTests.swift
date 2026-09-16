import Foundation
import Testing
@testable import ContextDock

@Suite("Unity bridge matching")
struct UnityBridgeMatchingTests {
    private func report(pid: pid_t = 500, start: Int64 = 1_000_000, updatedAgo: TimeInterval = 0, now: Date = Date(), path: String = "/p/game") -> UnityBridgeReport {
        UnityBridgeReport(pid: pid, processStartedAtUnixMs: start, editorSessionId: "s", projectPath: path, projectName: "game", unityVersion: "6000.0.58f1", updatedAtUnixMs: Int64((now.timeIntervalSince1970 - updatedAgo) * 1000))
    }

    @Test("pid and start time within tolerance match; a reused pid does not")
    func matching() {
        let key = ProcessInstanceKey.test(pid: 500, start: 1_000_000)
        #expect(UnityBridgeMatcher.matches(report(start: 1_000_000), process: key))
        #expect(UnityBridgeMatcher.matches(report(start: 1_001_500), process: key), "second-precision start times are tolerated")
        #expect(!UnityBridgeMatcher.matches(report(start: 1_010_000), process: key), "same pid, different process: ignored")
        #expect(!UnityBridgeMatcher.matches(report(pid: 501), process: key))
    }

    @Test("stale heartbeats are flagged but still assigned")
    func staleness() {
        let now = Date()
        let key = ProcessInstanceKey.test(pid: 500, start: 1_000_000)
        let assigned = UnityBridgeMatcher.assign(reports: [report(updatedAgo: 60, now: now)], to: [key], now: now)
        #expect(assigned[key]?.isStale == true)
        let fresh = UnityBridgeMatcher.assign(reports: [report(updatedAgo: 3, now: now)], to: [key], now: now)
        #expect(fresh[key]?.isStale == false)
    }

    @Test("the newest report wins and unmatched reports are dropped")
    func newestWins() {
        let now = Date()
        let key = ProcessInstanceKey.test(pid: 500, start: 1_000_000)
        let old = report(updatedAgo: 10, now: now, path: "/p/old")
        let new = report(updatedAgo: 1, now: now, path: "/p/new")
        let stray = report(pid: 999, now: now)
        let assigned = UnityBridgeMatcher.assign(reports: [old, stray, new], to: [key], now: now)
        #expect(assigned.count == 1)
        #expect(assigned[key]?.report.projectPath == "/p/new")
    }

    @Test("parser enforces schema, size and path sanity")
    func parsing() {
        let valid = Data(#"{"schemaVersion":1,"pid":12,"processStartedAtUnixMs":5,"editorSessionId":"x","projectPath":"/Users/me/Worktrees/music game","projectName":"music game","unityVersion":"2022.3.29f1","updatedAtUnixMs":9}"#.utf8)
        let parsed = UnityBridgeReader.parse(valid)
        #expect(parsed?.projectPath == "/Users/me/Worktrees/music game")
        #expect(parsed?.pid == 12)

        #expect(UnityBridgeReader.parse(Data(#"{"schemaVersion":2,"pid":12,"processStartedAtUnixMs":5,"editorSessionId":"x","projectPath":"/p","updatedAtUnixMs":9}"#.utf8)) == nil)
        #expect(UnityBridgeReader.parse(Data(#"{"schemaVersion":1,"pid":12,"processStartedAtUnixMs":5,"editorSessionId":"x","projectPath":"relative","updatedAtUnixMs":9}"#.utf8)) == nil)
        #expect(UnityBridgeReader.parse(Data("not json".utf8)) == nil)
        let huge = Data(repeating: 0x20, count: UnityBridgeReader.maxFileSize + 1)
        #expect(UnityBridgeReader.parse(huge) == nil)
    }

    @Test("reader ignores oversized files and purges very old ones")
    func readerDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdock-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("1-2.json")
        try Data(#"{"schemaVersion":1,"pid":1,"processStartedAtUnixMs":2,"editorSessionId":"x","projectPath":"/p","updatedAtUnixMs":9}"#.utf8).write(to: good)
        let big = dir.appendingPathComponent("3-4.json")
        try Data(repeating: 0x7B, count: 10_000).write(to: big)
        let old = dir.appendingPathComponent("5-6.json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: old.path)

        let reader = UnityBridgeReader(directory: dir)
        let reports = await reader.readReports()
        #expect(reports.count == 1)
        #expect(reports.first?.pid == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path), "files older than a day are purged")
        #expect(FileManager.default.fileExists(atPath: big.path), "oversized files are ignored, not deleted")
    }
}
