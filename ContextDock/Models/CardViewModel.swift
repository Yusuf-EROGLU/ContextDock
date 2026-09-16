import Foundation

/// Everything one card renders. Pure data; produced by `CardPresenter`.
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
    let projectPath: String?
    let isMinimized: Bool
    let isAppHidden: Bool
    let isActive: Bool
    let isStale: Bool
    let hasCustomName: Bool
    let context: WindowContext
    let accessibilityLabel: String
}

/// Pure resolution of what a card shows, following the spec priority:
/// window custom name → project rule → automatic context → window title.
enum CardPresenter {
    static let untitledWindowLabel = "Untitled window"

    static func resolve(
        window: WindowSnapshot,
        process: ProcessSnapshot,
        customization: SessionCustomization?,
        rule: ProjectRule?,
        context: WindowContext
    ) -> CardViewModel {
        let ruleApplies = rule != nil && context.hasTrustedProjectPath
        let appliedRule = ruleApplies ? rule : nil

        let customName = nonEmpty(customization?.name)
        let ruleLabel = nonEmpty(appliedRule?.customLabel)
        let structured = nonEmpty(context.structuredLabel)
        let projectName = nonEmpty(context.projectDisplayName)
        let rawTitle = nonEmpty(window.title)

        let title = customName ?? ruleLabel ?? structured ?? projectName ?? rawTitle ?? untitledWindowLabel
        let subtitle = subtitleLine(
            context: context,
            rawTitle: rawTitle,
            usedTitle: title,
            applicationName: process.applicationName
        )

        let badge = customization?.badge ?? appliedRule?.badge
        let color = customization?.colorToken ?? appliedRule?.colorToken ?? .none
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
            badge: badge,
            colorToken: color,
            rawTitle: rawTitle,
            projectPath: context.projectPath,
            isMinimized: window.isMinimized,
            isAppHidden: process.isHidden,
            isActive: isActive,
            isStale: window.isStale,
            hasCustomName: customName != nil,
            context: context,
            accessibilityLabel: a11y
        )
    }

    /// Second line: Git line for a trusted project path, otherwise the raw window title
    /// (or the app name when the title is already used on the first line).
    static func subtitleLine(
        context: WindowContext,
        rawTitle: String?,
        usedTitle: String,
        applicationName: String
    ) -> String? {
        if context.hasTrustedProjectPath, let line = gitLine(context: context) {
            return line
        }
        if let rawTitle, rawTitle != usedTitle {
            return rawTitle
        }
        if let branch = nonEmpty(context.branchName), context.contextSource == .structuredTitle {
            return branch
        }
        return applicationName
    }

    static func gitLine(context: WindowContext) -> String? {
        let folder = context.worktreeRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? context.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let staleSuffix = context.gitIsStale ? " (stale)" : ""

        switch context.gitStatus {
        case nil:
            return folder
        case .ok:
            let branchPart: String
            if context.isDetached == true {
                branchPart = "detached · \(context.shortCommit ?? "?")"
            } else if let branch = nonEmpty(context.branchName) {
                branchPart = context.isUnborn == true ? "\(branch) · no commits" : branch
            } else {
                branchPart = "unknown"
            }
            if let folder { return "\(folder) · \(branchPart)\(staleSuffix)" }
            return branchPart + staleSuffix
        case .notARepository:
            return [folder, "not a Git repository"].compactMap { $0 }.joined(separator: " · ")
        case .gitMissing:
            return [folder, "Git not found"].compactMap { $0 }.joined(separator: " · ")
        case .noAccess:
            return [folder, "no access"].compactMap { $0 }.joined(separator: " · ")
        case .unknown:
            return [folder, "unknown\(staleSuffix)"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
