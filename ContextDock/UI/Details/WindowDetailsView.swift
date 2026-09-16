import SwiftUI

/// Everything ContextDock knows about one window, including identity and raw AX facts.
struct WindowDetailsView: View {
    let card: CardViewModel
    let window: WindowSnapshot?
    let customization: SessionCustomization?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Application", card.applicationName)
                row("Bundle ID", card.bundleIdentifier ?? "—")
                row("PID", "\(card.process.pid)")
                row("Process start", processStart)
                row("Window title", card.rawTitle ?? "(untitled)")
                row("Role / subrole", "\(window?.role ?? "?") / \(window?.subrole ?? "—")")
                row("Minimized", (window?.isMinimized ?? false) ? "yes" : "no")
                row("Listed by app", (window?.listedByApplication ?? true) ? "yes" : "no (probe only)")
                row("Session ID", card.id.description)
                row("Custom name", customization?.name ?? "—")
                row("Project path", card.projectPath ?? "—")
                row("Context source", "\(card.context.contextSource.rawValue) (\(card.context.confidence.rawValue))")
                row("Worktree", card.context.worktreeRoot ?? "—")
                row("Branch", branchLine)
                row("Git status", gitStatus)
                if let note = card.context.conflictNote { row("Note", note) }
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .textSelection(.enabled)
    }

    private var processStart: String {
        switch card.process.start {
        case .unixMilliseconds(let ms):
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .standard)
        case .generation(let g):
            return "unknown (generation \(g))"
        }
    }

    private var branchLine: String {
        if card.context.isDetached == true { return "detached at \(card.context.shortCommit ?? "?")" }
        if let branch = card.context.branchName {
            return card.context.isUnborn == true ? "\(branch) (no commits yet)" : branch
        }
        return "—"
    }

    private var gitStatus: String {
        guard let status = card.context.gitStatus else { return "—" }
        let stale = card.context.gitIsStale ? " (stale)" : ""
        switch status {
        case .ok: return "ok" + stale
        case .notARepository: return "not a Git repository"
        case .gitMissing: return "Git not found"
        case .noAccess: return "no access"
        case .unknown(let reason): return "unknown: \(reason)" + stale
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(3).truncationMode(.middle)
        }
    }
}
