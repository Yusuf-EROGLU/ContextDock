import Foundation

/// Small visual marker shown next to the application icon. The icon stays the primary identity.
struct Badge: Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Codable {
        case emoji
        case symbol
    }

    var kind: Kind
    var value: String

    static func emoji(_ value: String) -> Badge { Badge(kind: .emoji, value: value) }
    static func symbol(_ name: String) -> Badge { Badge(kind: .symbol, value: name) }
}

/// Named accent colors; stored as tokens so the palette can follow the system appearance.
enum ColorToken: String, Sendable, Codable, CaseIterable, Hashable {
    case none
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink
    case gray

    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// How a manually attached project folder validated.
enum ProjectFolderValidation: Sendable, Hashable, Codable {
    case unityProject
    case folder(warning: String?)
    case unreadable
}

/// A project folder the user attached to a window in this session.
struct ProjectBinding: Sendable, Hashable, Codable {
    enum Scope: String, Sendable, Codable {
        case window
        case processInstance
    }

    var projectPath: String
    var scope: Scope
    var validation: ProjectFolderValidation
    var boundAt: Date

    var normalizedPath: String { PathNormalizer.normalize(projectPath) }
}

/// Session-only customization of a single window (dies with the window or with ContextDock).
struct SessionCustomization: Sendable, Hashable, Codable {
    var name: String?
    var badge: Badge?
    var colorToken: ColorToken?
    var projectBinding: ProjectBinding?

    var isEmpty: Bool {
        name == nil && badge == nil && colorToken == nil && projectBinding == nil
    }
}

/// Persistent per-project rule. It is applied only after a window is verified to belong to
/// the project; its existence never proves that a window belongs to that project.
struct ProjectRule: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    var applicationKind: ApplicationKind
    var projectPath: String
    var customLabel: String?
    var badge: Badge?
    var colorToken: ColorToken?
    var createdAt: Date
    var updatedAt: Date

    var contextKey: ContextKey {
        ContextKey(applicationKind: applicationKind, projectPath: projectPath)
    }
}
