import Foundation

/// Identity abstraction so the matching engine can be tested without AX.
protocol ElementIdentity {
    func isSameElement(as other: Self) -> Bool
}

/// Pure session-scoped matching of freshly listed elements against tracked windows of the
/// same process instance. Matching never crosses process instances and never uses titles.
enum WindowMatcher {
    struct Outcome: Equatable, Sendable {
        /// tracked id → index into the fresh array
        var matched: [WindowSessionID: Int]
        /// indices into the fresh array with no tracked counterpart
        var unmatchedFresh: [Int]
        /// tracked ids that no fresh element matched
        var missing: [WindowSessionID]
    }

    static func match<Element: ElementIdentity>(
        tracked: [(id: WindowSessionID, element: Element)],
        fresh: [Element]
    ) -> Outcome {
        var matched: [WindowSessionID: Int] = [:]
        var claimed = Set<Int>()
        var missing: [WindowSessionID] = []

        for entry in tracked {
            var found: Int?
            for (index, candidate) in fresh.enumerated() where !claimed.contains(index) {
                if entry.element.isSameElement(as: candidate) {
                    found = index
                    break
                }
            }
            if let found {
                matched[entry.id] = found
                claimed.insert(found)
            } else {
                missing.append(entry.id)
            }
        }

        let unmatched = fresh.indices.filter { !claimed.contains($0) }
        return Outcome(matched: matched, unmatchedFresh: unmatched, missing: missing)
    }
}
