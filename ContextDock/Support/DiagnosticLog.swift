import Foundation
import os

/// Small append-only diagnostics file, because the unified log is not always readable on the
/// user's machine. Only application names, counts and state transitions are written; never
/// window titles or paths. The file is truncated when it grows past `maxBytes`.
enum DiagnosticLog {
    static let url = PersistenceService.applicationSupportDirectory.appendingPathComponent("diagnostics.log")
    static let maxBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "com.yusuferoglu.ContextDock.diagnostics", qos: .utility)
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Tests exercise the same services; they must not write into the user's diagnostics file.
    private static let isEnabled: Bool = !AppDelegate.isRunningAsTestHost

    static func write(_ category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? Int, size > maxBytes {
                    try? fileManager.removeItem(at: url)
                }
                if !fileManager.fileExists(atPath: url.path) {
                    fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                Logger(subsystem: "com.yusuferoglu.ContextDock", category: "diagnostics").error("diagnostics write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
