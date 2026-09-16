import Foundation

/// Everything one window card renders. Pure data; produced by `CardPresenter`.
struct CardViewModel: Sendable, Hashable, Identifiable {
    let id: WindowSessionID
    let process: ProcessInstanceKey
    let applicationName: String
    let applicationKind: ApplicationKind
    let bundleIdentifier: String?
    let title: String
    let subtitle: String?
    let badge: Badge?
    let colorToken: ColorToken
    let rawTitle: String?
    let isMinimized: Bool
    let isAppHidden: Bool
    let isActive: Bool
    let isStale: Bool
    let hasCustomName: Bool
    let context: WindowContext
    let accessibilityLabel: String
}

/// A group card: name/badge plus its member cards in raise order.
struct GroupViewModel: Sendable, Hashable, Identifiable {
    let id: GroupID
    let title: String
    let subtitle: String
    let badge: Badge?
    let colorToken: ColorToken
    let members: [CardViewModel]
    let hasCustomName: Bool
    let isActive: Bool
    let accessibilityLabel: String
}

/// One entry of the bar in display order.
enum BarItem: Sendable, Hashable, Identifiable {
    case window(CardViewModel)
    case group(GroupViewModel)

    var id: BarItemID {
        switch self {
        case .window(let card): return .window(card.id)
        case .group(let group): return .group(group.id)
        }
    }
}

/// Pure resolution of what a card shows: custom name → automatic context → window title.
enum CardPresenter {
    static let untitledWindowLabel = "Untitled window"

    static func resolve(
        window: WindowSnapshot,
        process: ProcessSnapshot,
        customization: SessionCustomization?,
        context: WindowContext
    ) -> CardViewModel {
        let customName = nonEmpty(customization?.name)
        let structured = nonEmpty(context.structuredLabel)
        let projectName = nonEmpty(context.projectDisplayName)
        let rawTitle = nonEmpty(window.title)

        let title = customName ?? structured ?? projectName ?? rawTitle ?? untitledWindowLabel
        let subtitle = subtitleLine(context: context, rawTitle: rawTitle, usedTitle: title, applicationName: process.applicationName)
        let isActive = process.isActive && (window.isFocused || window.isMain)

        var a11y = "\(process.applicationName), \(title)"
        if let subtitle { a11y += ", \(subtitle)" }
        if window.isMinimized { a11y += ", minimized" }
        if process.isHidden { a11y += ", application hidden" }
        if window.isStale { a11y += ", information may be outdated" }

        return CardViewModel(
            id: window.id,
            process: window.process,
            applicationName: process.applicationName,
            applicationKind: process.kind,
            bundleIdentifier: process.bundleIdentifier,
            title: title,
            subtitle: subtitle,
            badge: customization?.badge,
            colorToken: customization?.colorToken ?? .none,
            rawTitle: rawTitle,
            isMinimized: window.isMinimized,
            isAppHidden: process.isHidden,
            isActive: isActive,
            isStale: window.isStale,
            hasCustomName: customName != nil,
            context: context,
            accessibilityLabel: a11y
        )
    }

    /// Second line: project/branch text from an automatic source when available, otherwise the
    /// raw title (or the app name when the title is already used on the first line).
    static func subtitleLine(context: WindowContext, rawTitle: String?, usedTitle: String, applicationName: String) -> String? {
        var parts: [String] = []
        if let project = nonEmpty(context.projectDisplayName), project != usedTitle { parts.append(project) }
        if let branch = nonEmpty(context.branchName) { parts.append(branch) }
        if !parts.isEmpty {
            return parts.joined(separator: " · ") + (context.isStale ? " (stale)" : "")
        }
        if let rawTitle, rawTitle != usedTitle {
            return rawTitle
        }
        return applicationName
    }

    static func resolveGroup(_ group: WindowGroup, members: [CardViewModel]) -> GroupViewModel {
        let customName = nonEmpty(group.name)
        let apps = orderedUnique(members.map(\.applicationName))
        let title = customName ?? apps.joined(separator: " + ")
        let subtitle = "\(members.count) windows" + (customName != nil ? " · \(apps.joined(separator: ", "))" : "")
        let isActive = members.contains { $0.isActive }
        let a11y = "Group \(title), \(members.count) windows: " + members.map { "\($0.applicationName) \($0.title)" }.joined(separator: ", ")
        return GroupViewModel(
            id: group.id,
            title: title,
            subtitle: subtitle,
            badge: group.badge,
            colorToken: group.colorToken ?? .none,
            members: members,
            hasCustomName: customName != nil,
            isActive: isActive,
            accessibilityLabel: a11y
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
