import Foundation

/// Accessibility permission state as observed by the AX worker.
enum PermissionState: Sendable, Hashable {
    case unknown
    case granted
    case denied
    /// Was granted earlier in this run and has since been withdrawn.
    case revoked

    var isGranted: Bool { self == .granted }
}

/// Immutable description of a running, user-facing application as passed from the main
/// actor (NSWorkspace) to the AX worker.
struct AppDescriptor: Sendable, Hashable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String
    let launchDate: Date?
    let isHidden: Bool
    let isActive: Bool
}

/// Plain data describing one process instance in a discovery snapshot.
struct ProcessSnapshot: Sendable, Hashable {
    let key: ProcessInstanceKey
    let bundleIdentifier: String?
    let applicationName: String
    let kind: ApplicationKind
    var isHidden: Bool
    var isActive: Bool
}

/// Plain data describing one accessible window. Only value types cross the AX boundary.
struct WindowSnapshot: Sendable, Hashable, Identifiable {
    let id: WindowSessionID
    let process: ProcessInstanceKey
    /// Monotonic counter assigned when the window was first seen; used for stable ordering.
    let firstSeenSequence: UInt64

    var title: String?
    var role: String?
    var subrole: String?
    var isMinimized: Bool
    var isMain: Bool
    var isFocused: Bool
    /// The last scan for this process failed or timed out; data may be outdated.
    var isStale: Bool
    /// `false` when the app no longer lists the window but the element still answers.
    var listedByApplication: Bool

    var hasTitle: Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Everything the UI needs from one discovery pass.
struct DiscoverySnapshot: Sendable, Hashable {
    var processes: [ProcessInstanceKey: ProcessSnapshot]
    /// Ordered by `firstSeenSequence`.
    var windows: [WindowSnapshot]
    var permission: PermissionState
    var generatedAt: Date

    static let empty = DiscoverySnapshot(processes: [:], windows: [], permission: .unknown, generatedAt: .distantPast)
}
