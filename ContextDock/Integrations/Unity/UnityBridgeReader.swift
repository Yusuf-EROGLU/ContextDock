import Foundation

/// Pure matching rules for Unity bridge heartbeats.
enum UnityBridgeMatcher {
    /// Mono reports process start times at second precision; allow a small, documented tolerance.
    static let startToleranceMs: Int64 = 2_000
    /// Heartbeats arrive every ~5 s; anything older than this is shown as stale.
    static let freshnessWindow: TimeInterval = 20

    /// A report belongs to a process instance only when pid *and* start time agree.
    static func matches(_ report: UnityBridgeReport, process key: ProcessInstanceKey) -> Bool {
        guard report.pid == key.pid else { return false }
        guard let start = key.startUnixMilliseconds else {
            // Without a kernel start time we cannot rule out PID reuse; require nothing more
            // than pid equality but the caller should treat this as lower confidence.
            return true
        }
        return abs(start - report.processStartedAtUnixMs) <= startToleranceMs
    }

    static func isStale(_ report: UnityBridgeReport, now: Date) -> Bool {
        now.timeIntervalSince(report.updatedAt) > freshnessWindow
    }

    /// Assigns reports to running Unity processes; unmatched reports are dropped.
    static func assign(reports: [UnityBridgeReport], to processes: [ProcessInstanceKey], now: Date) -> [ProcessInstanceKey: (report: UnityBridgeReport, isStale: Bool)] {
        var result: [ProcessInstanceKey: (UnityBridgeReport, Bool)] = [:]
        for key in processes {
            let candidates = reports.filter { matches($0, process: key) }
            guard let newest = candidates.max(by: { $0.updatedAtUnixMs < $1.updatedAtUnixMs }) else { continue }
            result[key] = (newest, isStale(newest, now: now))
        }
        return result
    }
}

/// Reads heartbeat files written by `Integrations/Unity/ContextDockBridge.cs`.
actor UnityBridgeReader {
    static let defaultDirectory = PersistenceService.applicationSupportDirectory.appendingPathComponent("Bridge/Unity", isDirectory: true)
    static let maxFileSize = 4_096
    static let purgeAge: TimeInterval = 24 * 60 * 60
    static let supportedSchemaVersion = 1

    private struct BridgeFile: Decodable {
        var schemaVersion: Int
        var pid: Int32
        var processStartedAtUnixMs: Int64
        var editorSessionId: String
        var projectPath: String
        var projectName: String?
        var unityVersion: String?
        var updatedAtUnixMs: Int64
    }

    private let directory: URL

    init(directory: URL = UnityBridgeReader.defaultDirectory) {
        self.directory = directory
    }

    /// Parses every valid heartbeat in the bridge directory and purges very old files.
    func readReports(now: Date = Date()) -> [UnityBridgeReport] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return []
        }
        var reports: [UnityBridgeReport] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) > Self.purgeAge {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let size = values.fileSize, size <= Self.maxFileSize else { continue }
            guard let data = try? Data(contentsOf: url), let report = Self.parse(data) else { continue }
            reports.append(report)
        }
        return reports
    }

    static func parse(_ data: Data) -> UnityBridgeReport? {
        guard data.count <= maxFileSize else { return nil }
        guard let file = try? JSONDecoder().decode(BridgeFile.self, from: data), file.schemaVersion == supportedSchemaVersion else { return nil }
        guard file.pid > 0, !file.projectPath.isEmpty, file.projectPath.hasPrefix("/") else { return nil }
        guard !file.projectPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return UnityBridgeReport(
            pid: file.pid,
            processStartedAtUnixMs: file.processStartedAtUnixMs,
            editorSessionId: file.editorSessionId,
            projectPath: file.projectPath,
            projectName: file.projectName ?? URL(fileURLWithPath: file.projectPath).lastPathComponent,
            unityVersion: file.unityVersion,
            updatedAtUnixMs: file.updatedAtUnixMs
        )
    }
}

/// Polls the bridge directory while Unity Editors are running and feeds matches to the store.
@MainActor
final class UnityBridgeMonitor {
    private let reader: UnityBridgeReader
    private let store: WindowStore
    private var loop: Task<Void, Never>?
    var interval: Duration = .seconds(5)

    init(reader: UnityBridgeReader = UnityBridgeReader(), store: WindowStore) {
        self.reader = reader
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func poll() async {
        let unityKeys = store.processKeys.filter { store.process(for: $0)?.kind.isUnityEditor == true }
        guard !unityKeys.isEmpty else { return }
        let reports = await reader.readReports()
        let now = Date()
        let assigned = UnityBridgeMatcher.assign(reports: reports, to: Array(unityKeys), now: now)
        for key in unityKeys {
            if let match = assigned[key] {
                store.setBridgeReport(match.report, isStale: match.isStale, for: key)
            } else {
                store.setBridgeReport(nil, isStale: false, for: key)
            }
        }
    }
}
