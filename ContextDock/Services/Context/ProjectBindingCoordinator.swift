import AppKit

/// Runs the "Attach Project Folder…" flow: folder picker, validation, scope choice and store
/// update. Never changes the chosen folder.
@MainActor
final class ProjectBindingCoordinator {
    private let store: WindowStore
    private let barState: BarState
    var onBound: (() -> Void)?

    init(store: WindowStore, barState: BarState) {
        self.store = store
        self.barState = barState
    }

    func attach(to id: WindowSessionID) {
        guard let card = store.card(for: id) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = card.applicationKind.isUnityEditor
            ? "Choose the Unity project folder (the one containing Assets and ProjectSettings) for “\(card.title)”."
            : "Choose the project folder for “\(card.title)”."
        if let existing = card.projectPath {
            panel.directoryURL = URL(fileURLWithPath: existing)
        }

        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.finish(id: id, card: card, url: url)
            }
        }
    }

    private func finish(id: WindowSessionID, card: CardViewModel, url: URL) {
        let validation = ProjectFolderValidator.validate(url)
        switch validation {
        case .unreadable:
            barState.showToast("Cannot read the selected folder")
            return
        case .folder:
            if card.applicationKind.isUnityEditor {
                let alert = NSAlert()
                alert.messageText = "This does not look like a Unity project"
                alert.informativeText = "The folder has no Assets and ProjectSettings directories. You can still attach it to show its Git branch."
                alert.addButton(withTitle: "Attach Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        case .unityProject:
            break
        }

        var scope: ProjectBinding.Scope = .window
        if card.applicationKind.isUnityEditor {
            let siblings = store.cards.filter { $0.process == card.process }.count
            if siblings > 1 {
                let alert = NSAlert()
                alert.messageText = "Apply to which windows?"
                alert.informativeText = "This Unity process has \(siblings) windows. Attach the project to only the selected window, or to all windows of this Unity instance."
                alert.addButton(withTitle: "This Window Only")
                alert.addButton(withTitle: "All \(siblings) Windows")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: scope = .window
                case .alertSecondButtonReturn: scope = .processInstance
                default: return
                }
            }
        }

        let binding = ProjectBinding(projectPath: url.path, scope: scope, validation: validation, boundAt: Date())
        store.bindProject(id, binding: binding)
        onBound?()
    }
}
