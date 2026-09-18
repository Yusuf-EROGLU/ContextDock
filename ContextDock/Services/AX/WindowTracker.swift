import Foundation

/// Attributes read from one window element during a scan.
struct WindowAttributes: Sendable, Hashable {
    var role: String?
    var subrole: String?
    var title: String?
    var isMinimized: Bool
    var isMain: Bool
}

/// Result of asking a possibly-missing element whether it still exists.
enum ElementProbe: Sendable, Equatable {
    case alive
    case dead
    case notResponding
}

/// Pure per-process-instance window tracking: keeps session ids stable across scans, marks
/// windows stale on failed scans, and removes them only on reliable evidence. Generic over
/// the element type so it can be tested without Accessibility.
struct WindowTracker<Element: ElementIdentity> {
    struct Tracked {
        let id: WindowSessionID
        var element: Element
        var snapshot: WindowSnapshot
        var missedScans: Int
    }

    enum ScanInput {
        /// The window list could not be read (timeout, dead connection…). Nothing is removed.
        case failure
        case success([(element: Element, attributes: WindowAttributes)])
    }

    struct Changes: Equatable {
        var added: [WindowSessionID] = []
        var removed: [WindowSessionID] = []
        /// Windows whose dead element was replaced by a new one with the same title (the app
        /// re-created its accessibility element, e.g. after sleep); identity is preserved.
        var readopted: [WindowSessionID] = []
    }

    let process: ProcessInstanceKey
    var missedScansBeforeProbe = 2
    private(set) var windows: [WindowSessionID: Tracked] = [:]

    init(process: ProcessInstanceKey) {
        self.process = process
    }

    var snapshots: [WindowSnapshot] {
        windows.values.map(\.snapshot).sorted { $0.firstSeenSequence < $1.firstSeenSequence }
    }

    func element(for id: WindowSessionID) -> Element? {
        windows[id]?.element
    }

    /// Applies one scan. `nextSequence` hands out global first-seen sequence numbers;
    /// `probe` is consulted for windows the app stopped listing.
    mutating func apply(
        _ input: ScanInput,
        nextSequence: () -> UInt64,
        probe: (Element) -> ElementProbe
    ) -> Changes {
        var changes = Changes()
        switch input {
        case .failure:
            markAllStale()

        case .success(let fresh) where fresh.isEmpty && !windows.isEmpty:
            // The lock screen (and some apps while suspended) report no windows at all although
            // the windows still exist. Treat it like a failed scan: keep everything, mark stale.
            // Real closes arrive as destroyed notifications or as dead probes once the app lists
            // windows again.
            markAllStale()

        case .success(let fresh):
            let tracked = windows.values
                .sorted { $0.snapshot.firstSeenSequence < $1.snapshot.firstSeenSequence }
                .map { (id: $0.id, element: $0.element) }
            var outcome = WindowMatcher.match(tracked: tracked, fresh: fresh.map(\.element))

            // Some apps hand out new AX elements for the same window (seen after sleep/lock).
            // When a tracked element is gone *and* exactly one new element carries the same
            // title, keep the session id and adopt the new element instead of churning cards.
            if !outcome.missing.isEmpty, !outcome.unmatchedFresh.isEmpty {
                var probes: [WindowSessionID: ElementProbe] = [:]
                func probed(_ id: WindowSessionID) -> ElementProbe {
                    if let known = probes[id] { return known }
                    let result = windows[id].map { probe($0.element) } ?? .dead
                    probes[id] = result
                    return result
                }
                func adopt(_ id: WindowSessionID, _ index: Int) {
                    windows[id]?.element = fresh[index].element
                    outcome.matched[id] = index
                    outcome.unmatchedFresh.removeAll { $0 == index }
                    outcome.missing.removeAll { $0 == id }
                    changes.readopted.append(id)
                }
                // Pass 1: unique same-title replacement.
                for id in outcome.missing {
                    guard let window = windows[id], let title = window.snapshot.title, !title.isEmpty else { continue }
                    let candidates = outcome.unmatchedFresh.filter { fresh[$0].attributes.title == title }
                    guard candidates.count == 1, let index = candidates.first, probed(id) == .dead else { continue }
                    adopt(id, index)
                }
                // Pass 2: every missing element is dead and exactly as many new elements appeared:
                // the app re-created its windows (seen after sleep); pair them in order.
                let dead = outcome.missing.filter { probed($0) == .dead }
                if !dead.isEmpty, dead.count == outcome.missing.count, dead.count == outcome.unmatchedFresh.count {
                    let orderedDead = dead.sorted { (windows[$0]?.snapshot.firstSeenSequence ?? 0) < (windows[$1]?.snapshot.firstSeenSequence ?? 0) }
                    let orderedFresh = outcome.unmatchedFresh.sorted()
                    for (id, index) in zip(orderedDead, orderedFresh) {
                        adopt(id, index)
                    }
                }
            }

            for (id, index) in outcome.matched {
                guard var window = windows[id] else { continue }
                Self.apply(fresh[index].attributes, to: &window.snapshot)
                window.snapshot.isStale = false
                window.snapshot.listedByApplication = true
                window.missedScans = 0
                windows[id] = window
            }

            for index in outcome.unmatchedFresh {
                let entry = fresh[index]
                let id = WindowSessionID()
                var snapshot = WindowSnapshot(
                    id: id,
                    process: process,
                    firstSeenSequence: nextSequence(),
                    title: nil,
                    role: nil,
                    subrole: nil,
                    isMinimized: false,
                    isMain: false,
                    isFocused: false,
                    isStale: false,
                    listedByApplication: true
                )
                Self.apply(entry.attributes, to: &snapshot)
                windows[id] = Tracked(id: id, element: entry.element, snapshot: snapshot, missedScans: 0)
                changes.added.append(id)
            }

            for id in outcome.missing {
                guard var window = windows[id] else { continue }
                window.missedScans += 1
                if window.missedScans >= missedScansBeforeProbe {
                    switch probe(window.element) {
                    case .dead:
                        windows[id] = nil
                        changes.removed.append(id)
                        continue
                    case .notResponding:
                        window.snapshot.isStale = true
                    case .alive:
                        window.snapshot.listedByApplication = false
                    }
                }
                windows[id] = window
            }
        }
        return changes
    }

    mutating func markAllStale() {
        for id in windows.keys {
            windows[id]?.snapshot.isStale = true
        }
    }

    mutating func remove(_ id: WindowSessionID) {
        windows[id] = nil
    }

    mutating func removeAll() -> [WindowSessionID] {
        let ids = Array(windows.keys)
        windows.removeAll()
        return ids
    }

    mutating func updateTitle(_ id: WindowSessionID, title: String?) {
        windows[id]?.snapshot.title = title
        windows[id]?.snapshot.isStale = false
    }

    mutating func updateMain(_ id: WindowSessionID, isMain: Bool) {
        windows[id]?.snapshot.isMain = isMain
    }

    mutating func updateMinimized(_ id: WindowSessionID, isMinimized: Bool) {
        windows[id]?.snapshot.isMinimized = isMinimized
    }

    /// Sets `isFocused` on the window whose element matches `focused` (none when nil).
    mutating func setFocused(_ focused: Element?) {
        for id in windows.keys {
            guard let window = windows[id] else { continue }
            windows[id]?.snapshot.isFocused = focused.map { window.element.isSameElement(as: $0) } ?? false
        }
    }

    private static func apply(_ attributes: WindowAttributes, to snapshot: inout WindowSnapshot) {
        snapshot.role = attributes.role
        snapshot.subrole = attributes.subrole
        snapshot.title = attributes.title
        snapshot.isMinimized = attributes.isMinimized
        snapshot.isMain = attributes.isMain
    }
}
