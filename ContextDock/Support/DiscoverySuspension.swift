import Foundation

enum DiscoverySuspensionReason: String, Sendable, Hashable {
    case systemSleep
    case displaySleep
    case screenLocked
    case sessionInactive
}

/// Balances independent macOS lifecycle signals. Callers pause on the first reason and resume
/// only after the final reason clears; duplicate notifications are deliberately idempotent.
struct DiscoverySuspensionState: Sendable, Equatable {
    private(set) var reasons: Set<DiscoverySuspensionReason> = []

    var isSuspended: Bool { !reasons.isEmpty }

    /// Returns true only for the transition from running to suspended.
    mutating func suspend(for reason: DiscoverySuspensionReason) -> Bool {
        let wasRunning = reasons.isEmpty
        reasons.insert(reason)
        return wasRunning
    }

    /// Returns true only for the transition from suspended back to running.
    mutating func resume(from reason: DiscoverySuspensionReason) -> Bool {
        guard reasons.remove(reason) != nil else { return false }
        return reasons.isEmpty
    }
}
