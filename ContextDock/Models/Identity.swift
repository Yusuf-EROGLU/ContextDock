import Foundation

/// Identifies one running process *instance*: a PID plus its start time. A PID alone is
/// not enough because the kernel reuses PIDs after a process exits.
struct ProcessInstanceKey: Hashable, Sendable, Codable {
    enum Start: Hashable, Sendable, Codable {
        /// Process start time from the kernel (or `NSRunningApplication.launchDate`).
        case unixMilliseconds(Int64)
        /// Fallback when no start time is available: a discovery generation counter local to
        /// this ContextDock run. PID reuse within one scan interval is not detectable in this mode.
        case generation(UInt64)
    }

    let pid: pid_t
    let start: Start

    var startUnixMilliseconds: Int64? {
        if case .unixMilliseconds(let ms) = start { return ms }
        return nil
    }
}

/// Session-scoped identity of one accessible window. Bound to a live AX element inside the
/// AX worker; it never changes while that element stays alive, no matter how the title changes.
/// It is not persisted and is never restored across ContextDock launches.
struct WindowSessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init() { rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }

    var description: String { rawValue.uuidString }
}

/// Coarse application classification used for project rules and integration adapters.
enum ApplicationKind: Hashable, Sendable, Codable {
    case unityEditor
    case ghostty
    case other(bundleIdentifier: String?)

    static let unityEditorBundleIdentifier = "com.unity3d.UnityEditor5.x"
    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"

    init(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case Self.unityEditorBundleIdentifier: self = .unityEditor
        case Self.ghosttyBundleIdentifier: self = .ghostty
        default: self = .other(bundleIdentifier: bundleIdentifier)
        }
    }

    var displayName: String {
        switch self {
        case .unityEditor: return "Unity"
        case .ghostty: return "Ghostty"
        case .other(let id): return id ?? "Unknown"
        }
    }

    var isUnityEditor: Bool { self == .unityEditor }
}

/// Persistent key for project rules: application kind plus a normalized, verified project path.
/// Branch names are deliberately not part of the key.
struct ContextKey: Hashable, Sendable, Codable {
    let applicationKind: ApplicationKind
    let normalizedProjectPath: String

    init(applicationKind: ApplicationKind, projectPath: String) {
        self.applicationKind = applicationKind
        self.normalizedProjectPath = PathNormalizer.normalize(projectPath)
    }
}

/// Path normalization shared by persistence and matching. Resolves symlinks and standardizes
/// the path, trims a trailing slash, and never changes letter case (the file system's case
/// sensitivity is not assumed).
enum PathNormalizer {
    static func normalize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var normalized = url.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
