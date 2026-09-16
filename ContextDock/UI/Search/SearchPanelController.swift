import AppKit
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    var query = "" { didSet { recompute() } }
    var selectedIndex = 0
    private(set) var results: [SearchCandidate] = []
    var candidates: [SearchCandidate] = [] { didSet { recompute() } }

    private func recompute() {
        results = SearchMatcher.rank(query, in: candidates)
        if selectedIndex >= results.count { selectedIndex = max(0, results.count - 1) }
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    var selected: SearchCandidate? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    let icon: (WindowSessionID) -> NSImage?
    var onChoose: (WindowSessionID) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search windows, projects, branches…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit {
                        if let selected = model.selected { onChoose(selected.id) }
                    }
            }
            .padding(14)
            Divider()
            if model.results.isEmpty {
                Text(model.candidates.isEmpty ? "No windows" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, candidate in
                                row(index: index, candidate: candidate)
                                    .id(candidate.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onChoose(candidate.id) }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: model.selectedIndex) { _, index in
                        if model.results.indices.contains(index) {
                            proxy.scrollTo(model.results[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private func row(index: Int, candidate: SearchCandidate) -> some View {
        HStack(spacing: 10) {
            if let image = icon(candidate.id) {
                Image(nsImage: image).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: "macwindow").frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.label).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(subtitle(candidate)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(index == model.selectedIndex ? Color.accentColor.opacity(0.22) : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == model.selectedIndex ? [.isSelected] : [])
    }

    private func subtitle(_ candidate: SearchCandidate) -> String {
        var parts: [String] = [candidate.applicationName]
        if let project = candidate.projectName { parts.append(project) }
        if let branch = candidate.branch { parts.append(branch) }
        if let title = candidate.title, title != candidate.label { parts.append(title) }
        return parts.joined(separator: " · ")
    }
}

/// Spotlight-style search panel that never activates ContextDock: it becomes key without
/// making the app active, so cancelling leaves the previous app untouched.
@MainActor
final class SearchPanelController {
    private let store: WindowStore
    private let preferences: Preferences
    private let model = SearchModel()
    private var panel: KeyablePanel?
    private var monitor: Any?
    private var previousFrontmostPid: pid_t?
    var onChoose: ((WindowSessionID) -> Void)?

    init(store: WindowStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        isShown ? cancel() : show()
    }

    func show() {
        previousFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        model.candidates = store.cards.enumerated().map { index, card in
            SearchCandidate(
                id: card.id,
                order: index,
                label: card.title,
                applicationName: card.applicationName,
                title: card.rawTitle,
                projectName: card.context.projectDisplayName,
                branch: card.context.branchName
            )
        }
        model.query = ""
        model.selectedIndex = 0

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = ScreenPlacement.resolve(preferences.screenSelection) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY + visible.height * 0.12))
        }
        installMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        dismiss()
        if NSApp.isActive, let pid = previousFrontmostPid, let app = NSRunningApplication(processIdentifier: pid) {
            _ = app.activate(from: .current, options: [])
        }
    }

    private func choose(_ id: WindowSessionID) {
        dismiss()
        onChoose?(id)
    }

    private func dismiss() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel()
        let view = SearchView(model: model, icon: { [weak self] id in
            guard let self, let card = self.store.card(for: id) else { return nil }
            return self.store.icon(for: card)
        }, onChoose: { [weak self] id in self?.choose(id) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: 560, height: 420))
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.onResignKey = { [weak self] in self?.dismiss() }
        return panel
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShown else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 125: model.moveSelection(by: 1); return nil       // ↓
            case 126: model.moveSelection(by: -1); return nil      // ↑
            case 36, 76:                                            // Return / Enter
                if let selected = model.selected { choose(selected.id) }
                return nil
            case 53: cancel(); return nil                           // Escape
            default: break
            }
            if flags == .command, let characters = event.charactersIgnoringModifiers,
               let digit = Int(characters), (1...9).contains(digit) {
                if model.results.indices.contains(digit - 1) {
                    choose(model.results[digit - 1].id)
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
