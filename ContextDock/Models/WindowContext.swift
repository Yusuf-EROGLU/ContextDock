import Foundation

enum ContextSource: String, Codable, Sendable, Hashable {
    case unityBridge
    case structuredTitle
    case windowTitle
    case none
}

enum ContextConfidence: String, Codable, Sendable, Hashable, Comparable {
    case unknown
    case inferred
    case verified

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .inferred: return 1
        case .verified: return 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Automatically derived, display-only context for one window (project name from the optional
/// Unity bridge, label/project/branch text from a structured terminal title). It is never used
/// as window identity and never persisted.
struct WindowContext: Sendable, Hashable, Codable {
    var projectDisplayName: String?
    var projectPath: String?
    var branchName: String?
    var structuredLabel: String?
    var contextSource: ContextSource
    var confidence: ContextConfidence
    var lastUpdatedAt: Date
    var isStale: Bool

    static func none(at date: Date = Date()) -> WindowContext {
        WindowContext(contextSource: .none, confidence: .unknown, lastUpdatedAt: date, isStale: false)
    }
}
