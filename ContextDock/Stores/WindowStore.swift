import AppKit
import Observation

/// Main-actor source of truth for the UI: latest discovery snapshot, session customizations,
/// groups/order and automatic contexts, merged into bar items.
@MainActor
@Observable
final class WindowStore {
    private(set) var snapshot: DiscoverySnapshot = .empty
    private(set) var cards: [CardViewModel] = []
    private(set) var items: [BarItem] = []
    private(set) var permission: PermissionState = .unknown
    private(set) var hasReceivedSnapshot = false
    private(set) var arrangement = BarArrangement()

    /// Unity bridge reports keyed by process instance (M3).
    private(set) var bridgeReports: [ProcessInstanceKey: (report: UnityBridgeReport, isStale: Bool)] = [:]

    let customizations: SessionCustomizationStore
    let persistence: PersistenceService
    let apps: RunningAppsProvider

    var onWindowsRemoved: (@MainActor (Set<WindowSessionID>) -> Void)?
    var onItemsChanged: (@MainActor () -> Void)?

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
            onWindowsRemoved?(removed)
        }
        let liveKeys = Set(newSnapshot.processes.keys)
        for key in bridgeReports.keys where !liveKeys.contains(key) {
            bridgeReports[key] = nil
        }
        arrangement.sync(windowsInFirstSeenOrder: newSnapshot.windows.map(\.id))
        for window in newSnapshot.windows where window.isFocused && newSnapshot.processes[window.process]?.isActive == true {
            arrangement.noteFocused(window.id)
        }
        rebuild()
    }

    var processKeys: Set<ProcessInstanceKey> { Set(snapshot.processes.keys) }
    func process(for key: ProcessInstanceKey) -> ProcessSnapshot? { snapshot.processes[key] }

    // MARK: - Customization

    func rename(_ id: WindowSessionID, to name: String?) {
        customizations.update(id) { $0.name = name?.isEmpty == true ? nil : name }
        rebuild()
    }

    func setBadge(_ id: WindowSessionID, badge: Badge?, color: ColorToken?) {
        customizations.update(id) {
            $0.badge = badge
            $0.colorToken = color == ColorToken.none ? nil : color
        }
        rebuild()
    }

    func resetCustomization(_ id: WindowSessionID) {
        customizations.reset(id)
        rebuild()
    }

    func resetAllCustomizations() {
        customizations.resetAll()
        for group in arrangement.groupList {
            arrangement.ungroup(group.id)
        }
        rebuild()
    }

    // MARK: - Groups and order

    @discardableResult
    func stack(_ dragged: BarItemID, onto target: BarItemID) -> GroupID? {
        let result = arrangement.stack(dragged, onto: target)
        rebuild()
        return result
    }

    func move(_ item: BarItemID, before target: BarItemID?) {
        arrangement.move(item, before: target)
        rebuild()
    }

    func removeFromGroup(_ window: WindowSessionID) {
        arrangement.removeFromGroup(window)
        rebuild()
    }

    func ungroup(_ id: GroupID) {
        arrangement.ungroup(id)
        rebuild()
    }

    func restoreGroup(id: GroupID, name: String?, badge: Badge?, colorToken: ColorToken?, members: [WindowSessionID]) {
        arrangement.restoreGroup(id: id, name: name, badge: badge, colorToken: colorToken, members: members)
        rebuild()
    }

    /// Applies a remembered customization without triggering separate rebuilds per field.
    func applyCustomization(_ customization: SessionCustomization, to id: WindowSessionID) {
        customizations.update(id) { $0 = customization }
        rebuild()
    }

    func renameGroup(_ id: GroupID, to name: String?) {
        arrangement.update(id) { $0.name = name?.isEmpty == true ? nil : name }
        rebuild()
    }

    func setGroupBadge(_ id: GroupID, badge: Badge?, color: ColorToken?) {
        arrangement.update(id) {
            $0.badge = badge
            $0.colorToken = color == ColorToken.none ? nil : color
        }
        rebuild()
    }

    func noteFocused(_ window: WindowSessionID) {
        arrangement.noteFocused(window)
    }

    func group(_ id: GroupID) -> WindowGroup? { arrangement.group(id) }
    func group(containing window: WindowSessionID) -> WindowGroup? { arrangement.group(containing: window) }

    // MARK: - Automatic context inputs (adapters)

    func setBridgeReport(_ report: UnityBridgeReport?, isStale: Bool, for key: ProcessInstanceKey) {
        let existing = bridgeReports[key]
        if existing?.report != report || existing?.isStale != isStale {
            bridgeReports[key] = report.map { ($0, isStale) }
            rebuild()
        }
    }

    // MARK: - Queries

    func card(for id: WindowSessionID) -> CardViewModel? {
        cards.first { $0.id == id }
    }

    func groupViewModel(_ id: GroupID) -> GroupViewModel? {
        for item in items {
            if case .group(let group) = item, group.id == id { return group }
        }
        return nil
    }

    func windowSnapshot(for id: WindowSessionID) -> WindowSnapshot? {
        snapshot.windows.first { $0.id == id }
    }

    func icon(for card: CardViewModel) -> NSImage? {
        apps.icon(for: card.process.pid)
    }

    func icon(for window: WindowSessionID) -> NSImage? {
        card(for: window).flatMap { icon(for: $0) }
    }

    // MARK: - Merge

    func rebuild() {
        var newCards: [CardViewModel] = []
        newCards.reserveCapacity(snapshot.windows.count)
        for window in snapshot.windows {
            guard let process = snapshot.processes[window.process] else { continue }
            var inputs = ContextInputs()
            inputs.rawTitle = window.title
            if let bridge = bridgeReports[window.process] {
                inputs.bridge = bridge.report
                inputs.bridgeIsStale = bridge.isStale
            }
            if let title = window.title {
                inputs.structuredTitle = StructuredTitleParser.parse(title)
            }
            let context = ContextResolver.resolve(inputs)
            newCards.append(CardPresenter.resolve(window: window, process: process, customization: customizations[window.id], context: context))
        }
        let byID = Dictionary(uniqueKeysWithValues: newCards.map { ($0.id, $0) })

        var newItems: [BarItem] = []
        for entry in arrangement.order {
            switch entry {
            case .window(let id):
                if let card = byID[id] { newItems.append(.window(card)) }
            case .group(let id):
                guard let group = arrangement.group(id) else { continue }
                let members = group.members.compactMap { byID[$0] }
                guard !members.isEmpty else { continue }
                newItems.append(.group(CardPresenter.resolveGroup(group, members: members)))
            }
        }

        let changed = newCards != cards || newItems != items
        cards = newCards
        items = newItems
        if changed { onItemsChanged?() }
    }
}
