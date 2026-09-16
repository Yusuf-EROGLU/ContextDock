import Foundation

/// Fields a card exposes to search.
struct SearchCandidate: Sendable, Hashable, Identifiable {
    let id: WindowSessionID
    let order: Int
    var label: String
    var applicationName: String
    var title: String?
    var projectName: String?
    var branch: String?
}

/// Case- and diacritic-insensitive matching over label, project, branch, app and title, with
/// weighted substring scores and a subsequence fallback. Empty query returns bar order.
enum SearchMatcher {
    static func rank(_ query: String, in candidates: [SearchCandidate]) -> [SearchCandidate] {
        let needle = fold(query)
        guard !needle.isEmpty else { return candidates.sorted { $0.order < $1.order } }
        let terms = needle.split(separator: " ").map(String.init)

        return candidates
            .compactMap { candidate -> (SearchCandidate, Int)? in
                var total = 0
                for term in terms {
                    guard let score = score(term: term, candidate: candidate) else { return nil }
                    total += score
                }
                return (candidate, total)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.order < rhs.0.order
            }
            .map(\.0)
    }

    private static func score(term: String, candidate: SearchCandidate) -> Int? {
        let fields: [(String?, Int)] = [
            (candidate.label, 5),
            (candidate.projectName, 4),
            (candidate.branch, 3),
            (candidate.applicationName, 2),
            (candidate.title, 1),
        ]
        var best: Int?
        for (value, weight) in fields {
            guard let value else { continue }
            let haystack = fold(value)
            if haystack.hasPrefix(term) {
                best = max(best ?? 0, weight * 10 + 5)
            } else if haystack.contains(term) {
                best = max(best ?? 0, weight * 10)
            } else if isSubsequence(term, of: haystack) {
                best = max(best ?? 0, weight)
            }
        }
        return best
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
