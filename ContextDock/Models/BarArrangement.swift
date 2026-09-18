import Foundation

/// Pure model of the bar's order and its groups. Windows appear in first-seen order until the
/// user moves them; groups occupy the slot of the card they were created on. Session-only.
struct BarArrangement: Sendable, Hashable {
    private(set) var order: [BarItemID] = []
    private(set) var groups: [GroupID: WindowGroup] = [:]

    init() {}

    // MARK: - Queries

    var groupList: [WindowGroup] { order.compactMap { if case .group(let id) = $0 { return groups[id] } else { return nil } } }

    func group(containing window: WindowSessionID) -> WindowGroup? {
        groups.values.first { $0.members.contains(window) }
    }

    func group(_ id: GroupID) -> WindowGroup? { groups[id] }

    var allWindowIDs: [WindowSessionID] {
        order.flatMap { item -> [WindowSessionID] in
            switch item {
            case .window(let id): return [id]
            case .group(let id): return groups[id]?.members ?? []
            }
        }
    }

    // MARK: - Sync with discovery

    /// Adds newly seen windows at the end (in the given order) and drops vanished ones.
    /// Groups that fall to one member dissolve into a plain card; empty groups disappear.
    mutating func sync(windowsInFirstSeenOrder ids: [WindowSessionID]) {
        let live = Set(ids)
        let known = Set(allWindowIDs)

        for id in ids where !known.contains(id) {
            order.append(.window(id))
        }

        order.removeAll { item in
            if case .window(let id) = item { return !live.contains(id) }
            return false
        }
        for (groupID, var group) in groups {
            group.members.removeAll { !live.contains($0) }
            if group.lastFocusedMember.map({ !live.contains($0) }) == true {
                group.lastFocusedMember = nil
            }
            groups[groupID] = group
        }
        dissolveSmallGroups()
    }

    // MARK: - Editing

    /// Drops `dragged` onto `target`: creates a group of both, or adds to the target's group.
    /// Returns the resulting group id.
    @discardableResult
    mutating func stack(_ dragged: BarItemID, onto target: BarItemID) -> GroupID? {
        guard dragged != target else { return nil }
        switch (dragged, target) {
        case (.window(let window), .window(let targetWindow)):
            detach(window)
            guard let index = order.firstIndex(of: .window(targetWindow)) else { return nil }
            let group = WindowGroup(members: [targetWindow, window])
            groups[group.id] = group
            order[index] = .group(group.id)
            return group.id

        case (.window(let window), .group(let groupID)):
            guard groups[groupID] != nil else { return nil }
            detach(window)
            groups[groupID]?.members.append(window)
            return groupID

        case (.group(let source), .window(let targetWindow)):
            guard let sourceGroup = groups[source], let index = order.firstIndex(of: .window(targetWindow)) else { return nil }
            var merged = sourceGroup
            merged.members = [targetWindow] + merged.members
            groups.removeValue(forKey: source)
            order.removeAll { $0 == .group(source) }
            groups[merged.id] = merged
            if let newIndex = order.firstIndex(of: .window(targetWindow)) {
                order[newIndex] = .group(merged.id)
            } else {
                order.insert(.group(merged.id), at: min(index, order.count))
            }
            return merged.id

        case (.group(let source), .group(let destination)):
            guard source != destination, let sourceGroup = groups[source], groups[destination] != nil else { return nil }
            groups[destination]?.members.append(contentsOf: sourceGroup.members)
            groups.removeValue(forKey: source)
            order.removeAll { $0 == .group(source) }
            return destination
        }
    }

    /// Moves `item` so it sits before `target` (or at the end when `target` is nil).
    /// A window inside a group is pulled out of the group first.
    mutating func move(_ item: BarItemID, before target: BarItemID?) {
        guard item != target else { return }
        if case .window(let window) = item, group(containing: window) != nil {
            detach(window)
            order.append(.window(window))
        }
        guard let from = order.firstIndex(of: item) else { return }
        let moving = order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) {
            order.insert(moving, at: to)
        } else {
            order.append(moving)
        }
        dissolveSmallGroups()
    }

    /// Removes a window from its group and places it as a plain card right after the group.
    mutating func removeFromGroup(_ window: WindowSessionID) {
        guard let group = group(containing: window) else { return }
        detach(window)
        if let index = order.firstIndex(of: .group(group.id)) {
            order.insert(.window(window), at: min(index + 1, order.count))
        } else {
            order.append(.window(window))
        }
        dissolveSmallGroups()
    }

    /// Dissolves a group; its members become plain cards in the group's slot.
    mutating func ungroup(_ id: GroupID) {
        guard let group = groups.removeValue(forKey: id), let index = order.firstIndex(of: .group(id)) else { return }
        order.replaceSubrange(index...index, with: group.members.map { BarItemID.window($0) })
    }

    /// Re-creates a remembered group with a known id. Members are pulled out of wherever they
    /// are; the group takes the slot of the first member. Requires at least two members.
    mutating func restoreGroup(id: GroupID, name: String?, badge: Badge?, colorToken: ColorToken?, members: [WindowSessionID]) {
        let live = members.filter { allWindowIDs.contains($0) }
        guard live.count >= 2, groups[id] == nil else { return }
        let anchorIndex = order.firstIndex(of: .window(live[0])) ?? order.count
        for window in live { detach(window) }
        let group = WindowGroup(id: id, name: name, badge: badge, colorToken: colorToken, members: live)
        groups[id] = group
        order.insert(.group(id), at: min(anchorIndex, order.count))
        dissolveSmallGroups()
    }

    mutating func update(_ id: GroupID, _ mutate: (inout WindowGroup) -> Void) {
        guard var group = groups[id] else { return }
        mutate(&group)
        groups[id] = group
    }

    mutating func noteFocused(_ window: WindowSessionID) {
        guard let group = group(containing: window) else { return }
        groups[group.id]?.lastFocusedMember = window
    }

    // MARK: - Helpers

    private mutating func detach(_ window: WindowSessionID) {
        order.removeAll { $0 == .window(window) }
        for (id, var group) in groups where group.members.contains(window) {
            group.members.removeAll { $0 == window }
            if group.lastFocusedMember == window { group.lastFocusedMember = nil }
            groups[id] = group
        }
    }

    private mutating func dissolveSmallGroups() {
        for (id, group) in groups where group.members.count <= 1 {
            groups.removeValue(forKey: id)
            if let index = order.firstIndex(of: .group(id)) {
                order.replaceSubrange(index...index, with: group.members.map { BarItemID.window($0) })
            } else {
                order.append(contentsOf: group.members.map { BarItemID.window($0) })
            }
        }
    }
}
