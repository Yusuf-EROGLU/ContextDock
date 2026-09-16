import Foundation

/// Checks a user-selected folder. Never modifies anything.
enum ProjectFolderValidator {
    static func validate(_ url: URL, fileManager: FileManager = .default) -> ProjectFolderValidation {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path) else {
            return .unreadable
        }
        if isUnityProject(url, fileManager: fileManager) {
            return .unityProject
        }
        return .folder(warning: nil)
    }

    /// A Unity project has `Assets/` and `ProjectSettings/` directories.
    static func isUnityProject(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        let assets = url.appendingPathComponent("Assets", isDirectory: true)
        let settings = url.appendingPathComponent("ProjectSettings", isDirectory: true)
        guard fileManager.fileExists(atPath: assets.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard fileManager.fileExists(atPath: settings.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return true
    }

    /// Unity's `ProjectSettings/ProjectVersion.txt` first line, e.g. `m_EditorVersion: 2022.3.29f1`.
    static func unityEditorVersion(_ url: URL) -> String? {
        let file = url.appendingPathComponent("ProjectSettings/ProjectVersion.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("m_EditorVersion:") {
            return line.dropFirst("m_EditorVersion:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
