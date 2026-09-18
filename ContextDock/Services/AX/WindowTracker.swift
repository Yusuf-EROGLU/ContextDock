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

        case .success(let fresh):
            let tracked = windows.values
                .sorted { $0.snapshot.firstSeenSequence < $1.snapshot.firstSeenSequence }
                .map { (id: $0.id, element: $0.element) }
            var outcome = WindowMatcher.match(tracked: tracked, fresh: fresh.map(\.element))

            // Some apps hand out new AX elements for the same window (seen after sleep/lock).
            // When a tracked element is gone *and* exactly one new element carries the same
            // title, keep the session id and adopt the new element instead of churning cards.
            if !outcome.missing.isEmpty, !outcome.unmatchedFresh.isEmpty {
                for id in outcome.missing {
                    guard let window = windows[id], let title = window.snapshot.title, !title.isEmpty else { continue }
                    let candidates = outcome.unmatchedFresh.filter { fresh[$0].attributes.title == title }
                    guard candidates.count == 1, let index = candidates.first, probe(window.element) == .dead else { continue }
                    windows[id]?.element = fresh[index].element
                    outcome.matched[id] = index
                    outcome.unmatchedFresh.removeAll { $0 == index }
                    outcome.missing.removeAll { $0 == id }
                    changes.readopted.append(id)
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
