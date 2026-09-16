import Foundation

/// Decides which AX elements count as independent work windows. Pure and testable.
/// Title text is never used for filtering.
enum WindowFilter {
    enum Decision: Sendable, Equatable {
        case include
        case includeAsAuxiliary
        case exclude(reason: String)
    }

    static let windowRole = "AXWindow"
    static let standardSubrole = "AXStandardWindow"
    static let auxiliarySubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXDecorative",
    ]

    /// - Parameters:
    ///   - role: value of `kAXRoleAttribute`, if readable.
    ///   - subrole: value of `kAXSubroleAttribute`; `nil` when unsupported or absent.
    static func decide(role: String?, subrole: String?) -> Decision {
        guard role == windowRole else {
            return .exclude(reason: "role \(role ?? "nil") is not a window")
        }
        guard let subrole, !subrole.isEmpty, subrole != "AXUnknown" else {
            // Custom toolkits (Unity, some cross-platform apps) omit the subrole; treat as standard.
            return .include
        }
        if subrole == standardSubrole {
            return .include
        }
        if auxiliarySubroles.contains(subrole) {
            return .includeAsAuxiliary
        }
        return .include
    }

    static func shouldTrack(role: String?, subrole: String?, showAuxiliary: Bool) -> Bool {
        switch decide(role: role, subrole: subrole) {
        case .include: return true
        case .includeAsAuxiliary: return showAuxiliary
        case .exclude: return false
        }
    }
}
