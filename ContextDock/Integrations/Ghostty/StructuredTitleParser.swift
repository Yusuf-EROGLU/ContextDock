import Foundation

/// Parses the optional structured terminal title `CDOCK:v1|label=…|project=…|branch=…`.
/// The result is display-only: it is never treated as a path, never persisted, and never
/// used as window identity. Anything malformed yields `nil` so the plain title is shown.
enum StructuredTitleParser {
    static let prefix = "CDOCK:v1|"
    static let maxFieldLength = 128

    static func parse(_ title: String) -> StructuredTitle? {
        guard title.hasPrefix(prefix) else { return nil }
        let body = title.dropFirst(prefix.count)
        var result = StructuredTitle()
        var sawField = false

        for pair in body.split(separator: "|", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals]
            let encoded = String(pair[pair.index(after: equals)...])
            guard let value = encoded.removingPercentEncoding, isSafe(value) else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            switch key {
            case "label": result.label = cleaned
            case "project": result.project = cleaned
            case "branch": result.branch = cleaned
            default: continue
            }
            sawField = true
        }
        return sawField ? result : nil
    }

    private static func isSafe(_ value: String) -> Bool {
        guard value.count <= maxFieldLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.newlines.contains(scalar)
        }
    }
}
