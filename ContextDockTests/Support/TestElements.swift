import Foundation
@testable import ContextDock

/// Stand-in for an AX element: identity is the integer, like `CFEqual` on live refs.
struct IntElement: ElementIdentity, Hashable, Sendable {
    let id: Int
    func isSameElement(as other: IntElement) -> Bool { id == other.id }
}

extension WindowAttributes {
    static func window(_ title: String?, subrole: String? = "AXStandardWindow", minimized: Bool = false, main: Bool = false) -> WindowAttributes {
        WindowAttributes(role: "AXWindow", subrole: subrole, title: title, isMinimized: minimized, isMain: main)
    }
}

extension ProcessInstanceKey {
    static func test(pid: pid_t = 100, start: Int64 = 1_000) -> ProcessInstanceKey {
        ProcessInstanceKey(pid: pid, start: .unixMilliseconds(start))
    }
}

extension ProcessSnapshot {
    static func test(key: ProcessInstanceKey = .test(), kind: ApplicationKind = .ghostty, name: String = "Ghostty", active: Bool = false, hidden: Bool = false) -> ProcessSnapshot {
        ProcessSnapshot(key: key, bundleIdentifier: kind == .ghostty ? ApplicationKind.ghosttyBundleIdentifier : nil, applicationName: name, kind: kind, isHidden: hidden, isActive: active)
    }
}

extension WindowSnapshot {
    static func test(id: WindowSessionID = WindowSessionID(), process: ProcessInstanceKey = .test(), sequence: UInt64 = 1, title: String? = "Title", minimized: Bool = false, main: Bool = false, focused: Bool = false, stale: Bool = false) -> WindowSnapshot {
        WindowSnapshot(id: id, process: process, firstSeenSequence: sequence, title: title, role: "AXWindow", subrole: "AXStandardWindow", isMinimized: minimized, isMain: main, isFocused: focused, isStale: stale, listedByApplication: true)
    }
}

/// Monotonic sequence source for tracker tests.
final class SequenceCounter {
    private var value: UInt64 = 0
    func next() -> UInt64 { value += 1; return value }
}
