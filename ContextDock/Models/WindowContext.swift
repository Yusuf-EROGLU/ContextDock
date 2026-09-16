import Foundation

enum ContextSource: String, Codable, Sendable, Hashable {
    case manual
    case unityBridge
    case processArguments
    case structuredTitle
    case windowTitle
    case none
}

enum ContextConfidence: String, Codable, Sendable, Hashable, Comparable {
    case unknown
    case inferred
    case verified
    case userConfirmed

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .inferred: return 1
        case .verified: return 2
        case .userConfirmed: return 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Whether the associated project path may be trusted for Git queries and rule matching.
    var isPathTrusted: Bool { self >= .verified }
}

/// Outcome classification of a Git lookup. The cases are deliberately distinct so the UI can
/// tell "not a repo" from "git missing" from "no access".
enum GitStatus: Sendable, Hashable, Codable {
    case ok
    case notARepository
    case gitMissing
    case noAccess
    case unknown(reason: String)
}

/// Git facts about one worktree root. Cached by worktree root, never by repository name.
struct GitInfo: Sendable, Hashable, Codable {
    var worktreeRoot: String
    var repositoryRoot: String?
    var gitDirectory: String?
    var commonDirectory: String?
    var branchName: String?
    var shortCommit: String?
    var isDetached: Bool
    var isUnborn: Bool
    var status: GitStatus
    var lastUpdatedAt: Date
    var isStale: Bool

    var worktreeFolderName: String {
        URL(fileURLWithPath: worktreeRoot).lastPathComponent
    }
}

/// Resolved project/branch context for one window. Display customization (user label, badge)
/// is kept separately so the branch keeps updating even when the user renamed the card.
struct WindowContext: Sendable, Hashable, Codable {
    var projectDisplayName: String?
    var projectPath: String?
    var repositoryRoot: String?
    var worktreeRoot: String?
    var branchName: String?
    var shortCommit: String?
    var isDetached: Bool?
    var isUnborn: Bool?
    var gitStatus: GitStatus?
    var gitIsStale: Bool
    var contextSource: ContextSource
    var confidence: ContextConfidence
    var lastUpdatedAt: Date
    var isStale: Bool
    /// Set when an automatic source disagrees with the user's manual binding.
    var conflictNote: String?
    /// Display-only label carried by a structured terminal title (never a path).
    var structuredLabel: String?

    static func none(at date: Date = Date()) -> WindowContext {
        WindowContext(
            gitIsStale: false,
            contextSource: .none,
            confidence: .unknown,
            lastUpdatedAt: date,
            isStale: false
        )
    }

    var hasTrustedProjectPath: Bool {
        projectPath != nil && confidence.isPathTrusted
    }
}
