import Foundation

/// Finds a usable `git` without triggering the Command Line Tools installer dialog that the
/// `/usr/bin/git` shim shows when no developer tools are installed.
enum GitExecutableLocator {
    static let candidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    static func locate(fileManager: FileManager = .default) -> URL? {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let xcodeGit = xcodeGit(fileManager: fileManager) {
            return xcodeGit
        }
        // The shim is only safe when a developer directory is actually installed.
        if fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git"),
           fileManager.isExecutableFile(atPath: "/usr/bin/git") {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return nil
    }

    private static func xcodeGit(fileManager: FileManager) -> URL? {
        let applications = URL(fileURLWithPath: "/Applications")
        guard let items = try? fileManager.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.lastPathComponent.hasPrefix("Xcode") && item.pathExtension == "app" {
            let git = item.appendingPathComponent("Contents/Developer/usr/bin/git")
            if fileManager.isExecutableFile(atPath: git.path) {
                return git
            }
        }
        return nil
    }
}
