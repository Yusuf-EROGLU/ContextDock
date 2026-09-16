import AppKit
import Observation

/// Main-actor source of truth for the UI: latest discovery snapshot, session customizations,
/// persisted project rules and per-window contexts, merged into `CardViewModel`s.
@MainActor
@Observable
final class WindowStore {
    private(set) var snapshot: DiscoverySnapshot = .empty
    private(set) var cards: [CardViewModel] = []
    private(set) var permission: PermissionState = .unknown
    private(set) var hasReceivedSnapshot = false

    /// Automatic (non-manual) context sources keyed by window, filled by adapters (M2/M3).
    private(set) var automaticInputs: [WindowSessionID: ContextInputs] = [:]
    /// Git facts keyed by normalized worktree/project path (M2).
    private(set) var gitInfo: [String: GitInfo] = [:]
    /// Unity `-projectPath` hints keyed by process instance (M2, optional adapter).
    private(set) var processArgumentHints: [ProcessInstanceKey: ProcessArgumentsHint] = [:]
    /// Unity bridge reports keyed by process instance (M3).
    private(set) var bridgeReports: [ProcessInstanceKey: (report: UnityBridgeReport, isStale: Bool)] = [:]

    let customizations: SessionCustomizationStore
    let persistence: PersistenceService
    let apps: RunningAppsProvider

    var onWindowsRemoved: (@MainActor (Set<WindowSessionID>) -> Void)?
    var onCardsChanged: (@MainActor () -> Void)?

    init(customizations: SessionCustomizationStore, persistence: PersistenceService, apps: RunningAppsProvider) {
        self.customizations = customizations
        self.persistence = persistence
        self.apps = apps
    }

    // MARK: - Snapshot intake

    func apply(_ newSnapshot: DiscoverySnapshot) {
        let previousIDs = Set(snapshot.windows.map(\.id))
        snapshot = newSnapshot
        permission = newSnapshot.permission
        hasReceivedSnapshot = true

        let liveIDs = Set(newSnapshot.windows.map(\.id))
        let removed = previousIDs.subtracting(liveIDs)
        if !removed.isEmpty {
            customizations.purge(keeping: liveIDs)
            for id in removed { automaticInputs[id] = nil }
            onWindowsRemoved?(removed)
        }
        let liveKeys = Set(newSnapshot.processes.keys)
        for key in processArgumentHints.keys where !liveKeys.contains(key) {
            processArgumentHints[key] = nil
        }
        for key in bridgeReports.keys where !liveKeys.contains(key) {
            bridgeReports[key] = nil
        }
        rebuildCards()
    }

    var processKeys: Set<ProcessInstanceKey> { Set(snapshot.processes.keys) }

    func process(for key: ProcessInstanceKey) -> ProcessSnapshot? { snapshot.processes[key] }

    // MARK: - Customization

    func rename(_ id: WindowSessionID, to name: String?) {
        customizations.update(id) { $0.name = name?.isEmpty == true ? nil : name }
        rebuildCards()
    }

    func setBadge(_ id: WindowSessionID, badge: Badge?, color: ColorToken?) {
        customizations.update(id) {
            $0.badge = badge
            $0.colorToken = color == ColorToken.none ? nil : color
        }
        rebuildCards()
    }

    func bindProject(_ id: WindowSessionID, binding: ProjectBinding?) {
        let target = card(for: id)
        var affected: [WindowSessionID] = [id]
        if binding?.scope == .processInstance, let target {
            affected = cards.filter { $0.process == target.process }.map(\.id)
        }
        for windowID in affected {
            customizations.update(windowID) { $0.projectBinding = binding }
        }
        rebuildCards()
    }

    func resetCustomization(_ id: WindowSessionID) {
        customizations.reset(id)
        rebuildCards()
    }

    func resetAllCustomizations(includingRules: Bool) {
        customizations.resetAll()
        if includingRules {
            persistence.update { $0.projectRules.removeAll() }
        }
        rebuildCards()
    }

    // MARK: - Project rules

    func rule(for key: ContextKey) -> ProjectRule? {
        persistence.state.projectRules.first { $0.contextKey == key }
    }

    func upsertRule(kind: ApplicationKind, projectPath: String, mutate: (inout ProjectRule) -> Void) {
        let key = ContextKey(applicationKind: kind, projectPath: projectPath)
        persistence.update { state in
            if let index = state.projectRules.firstIndex(where: { $0.contextKey == key }) {
                mutate(&state.projectRules[index])
                state.projectRules[index].updatedAt = Date()
            } else {
                var rule = ProjectRule(
                    id: UUID(),
                    applicationKind: kind,
                    projectPath: key.normalizedProjectPath,
                    customLabel: nil,
                    badge: nil,
                    colorToken: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                mutate(&rule)
                state.projectRules.append(rule)
            }
        }
        rebuildCards()
    }

    func deleteRule(id: UUID) {
        persistence.update { $0.projectRules.removeAll { $0.id == id } }
        rebuildCards()
    }

    // MARK: - Automatic context inputs (adapters)

    func setAutomaticInputs(_ inputs: ContextInputs?, for id: WindowSessionID) {
        automaticInputs[id] = inputs
        rebuildCards()
    }

    func setProcessArgumentsHint(_ hint: ProcessArgumentsHint?, for key: ProcessInstanceKey) {
        if processArgumentHints[key] != hint {
            processArgumentHints[key] = hint
            rebuildCards()
        }
    }

    func setBridgeReport(_ report: UnityBridgeReport?, isStale: Bool, for key: ProcessInstanceKey) {
        let existing = bridgeReports[key]
        if existing?.report != report || existing?.isStale != isStale {
            bridgeReports[key] = report.map { ($0, isStale) }
            rebuildCards()
        }
    }

    func setGitInfo(_ info: GitInfo?, for path: String) {
        let key = PathNormalizer.normalize(path)
        if gitInfo[key] != info {
            gitInfo[key] = info
            rebuildCards()
        }
    }

    /// Trusted project paths currently shown (for Git refresh scheduling).
    var trustedProjectPaths: Set<String> {
        Set(cards.compactMap { $0.context.hasTrustedProjectPath ? $0.context.projectPath : nil })
    }

    // MARK: - Queries

    func card(for id: WindowSessionID) -> CardViewModel? {
        cards.first { $0.id == id }
    }

    func windowSnapshot(for id: WindowSessionID) -> WindowSnapshot? {
        snapshot.windows.first { $0.id == id }
    }

    func icon(for card: CardViewModel) -> NSImage? {
        apps.icon(for: card.process.pid)
    }

    func context(for id: WindowSessionID) -> WindowContext {
        card(for: id)?.context ?? .none()
    }

    // MARK: - Merge

    func rebuildCards() {
        var result: [CardViewModel] = []
        result.reserveCapacity(snapshot.windows.count)
        for window in snapshot.windows {
            guard let process = snapshot.processes[window.process] else { continue }
            let customization = customizations[window.id]
            var inputs = automaticInputs[window.id] ?? ContextInputs()
            inputs.manual = customization?.projectBinding
            if inputs.processArguments == nil { inputs.processArguments = processArgumentHints[window.process] }
            if inputs.bridge == nil, let bridge = bridgeReports[window.process] {
                inputs.bridge = bridge.report
                inputs.bridgeIsStale = bridge.isStale
            }
            inputs.rawTitle = window.title
            if inputs.structuredTitle == nil, let title = window.title {
                inputs.structuredTitle = StructuredTitleParser.parse(title)
            }
            var context = ContextResolver.resolve(inputs)
            if context.hasTrustedProjectPath, let path = context.projectPath {
                inputs.git = gitInfo[PathNormalizer.normalize(path)]
                context = ContextResolver.resolve(inputs)
            }
            let rule = context.hasTrustedProjectPath && context.projectPath != nil
                ? self.rule(for: ContextKey(applicationKind: process.kind, projectPath: context.projectPath!))
                : nil
            result.append(CardPresenter.resolve(
                window: window,
                process: process,
                customization: customization,
                rule: rule,
                context: context
            ))
        }
        if result != cards {
            cards = result
            onCardsChanged?()
        }
    }
}
