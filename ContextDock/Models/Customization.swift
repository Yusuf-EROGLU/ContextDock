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

/// Session-only customization of a single window (dies with the window or with ContextDock).
struct SessionCustomization: Sendable, Hashable, Codable {
    var name: String?
    var badge: Badge?
    var colorToken: ColorToken?

    var isEmpty: Bool {
        name == nil && badge == nil && colorToken == nil
    }
}

/// Session-only identifier of a card group.
struct GroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init() { rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString }
}

/// A user-made stack of windows that belong together (for example the Unity, Rider and Ghostty
/// windows of one task). Groups live only for the current ContextDock run.
struct WindowGroup: Sendable, Hashable, Codable, Identifiable {
    var id: GroupID
    var name: String?
    var badge: Badge?
    var colorToken: ColorToken?
    /// Ordered members; the order is the order in which windows are raised.
    var members: [WindowSessionID]
    /// Member that received keyboard focus most recently; gets focus when the group opens.
    var lastFocusedMember: WindowSessionID?

    init(id: GroupID = GroupID(), name: String? = nil, badge: Badge? = nil, colorToken: ColorToken? = nil, members: [WindowSessionID], lastFocusedMember: WindowSessionID? = nil) {
        self.id = id
        self.name = name
        self.badge = badge
        self.colorToken = colorToken
        self.members = members
        self.lastFocusedMember = lastFocusedMember
    }

    /// Window to focus when the group is opened: last focused member if still present, else the first.
    var focusTarget: WindowSessionID? {
        if let last = lastFocusedMember, members.contains(last) { return last }
        return members.first
    }
}

/// What ContextDock remembers about a window across launches. Windows have no durable
/// identity, so this is a best-effort description used to re-attach names and groups.
struct WindowFingerprint: Sendable, Hashable, Codable {
    var bundleIdentifier: String?
    var applicationName: String
    var title: String?
    var pid: pid_t?
    var processStartUnixMs: Int64?
}

/// A remembered window: its fingerprint plus the customization to restore.
struct PersistedWindow: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    var fingerprint: WindowFingerprint
    var customization: SessionCustomization
}

/// A remembered group; `members` are `PersistedWindow` ids in raise order.
struct PersistedGroup: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    var name: String?
    var badge: Badge?
    var colorToken: ColorToken?
    var members: [UUID]
}

/// An item shown in the bar: a single window card or a group card.
enum BarItemID: Hashable, Sendable, Codable {
    case window(WindowSessionID)
    case group(GroupID)
}
