import Foundation
import Testing
@testable import ContextDock

/// Scripted focus port that records the call sequence.
@AXActor
final class MockFocusPort: FocusPort {
    var calls: [String] = []
    var probeResults: [FocusProbe]
    var frontmost: [pid_t?]
    var hidden: Bool? = false
    var minimized: Bool? = false
    var focusedResults: [Bool?]
    var mainResult: Bool? = true
    var activateResult = true
    var raiseResult = true
    let targetPid: pid_t = 500

    nonisolated init(probeResults: [FocusProbe] = [.alive(pid: 500)], frontmost: [pid_t?] = [], focusedResults: [Bool?] = []) {
        self.probeResults = probeResults
        self.frontmost = frontmost
        self.focusedResults = focusedResults
    }

    private func pop<T>(_ array: inout [T], default value: T) -> T {
        array.isEmpty ? value : array.removeFirst()
    }

    func probe(_ id: WindowSessionID) -> FocusProbe { calls.append("probe"); return pop(&probeResults, default: .alive(pid: targetPid)) }
    func frontmostProcessID() -> pid_t? { calls.append("frontmost"); return pop(&frontmost, default: targetPid) }
    func ownProcessID() -> pid_t { 1 }
    func applicationIsHidden(_ pid: pid_t) -> Bool? { calls.append("isHidden"); return hidden }
    func setApplicationHidden(_ pid: pid_t, _ hidden: Bool) -> Bool { calls.append("unhide"); self.hidden = hidden; return true }
    func windowIsMinimized(_ id: WindowSessionID) -> Bool? { calls.append("isMinimized"); return minimized }
    func setWindowMinimized(_ id: WindowSessionID, _ value: Bool) -> Bool { calls.append("unminimize"); minimized = value; return true }
    func activateApplication(_ pid: pid_t) async -> Bool { calls.append("activate"); return activateResult }
    func setApplicationFrontmost(_ pid: pid_t) -> Bool { calls.append("setFrontmost"); return true }
    func raiseWindow(_ id: WindowSessionID) -> Bool { calls.append("raise"); return raiseResult }
    func setWindowMain(_ id: WindowSessionID) -> Bool { calls.append("setMain"); return true }
    func setFocusedWindow(_ id: WindowSessionID) -> Bool { calls.append("setFocused"); return true }
    func windowIsFocused(_ id: WindowSessionID) -> Bool? { calls.append("isFocused"); return pop(&focusedResults, default: true) }
    func windowIsMain(_ id: WindowSessionID) -> Bool? { calls.append("isMain"); return mainResult }
    func sleep(for duration: Duration) async { calls.append("sleep") }
}

@Suite("FocusService")
struct FocusServiceTests {
    @Test("happy path follows the specified order and verifies")
    @AXActor func happyPath() async {
        let port = MockFocusPort(frontmost: [500], focusedResults: [true])
        let service = FocusService(port: port)
        let outcome = await service.focus(WindowSessionID())
        #expect(outcome == .verified)
        let sequence = port.calls.filter { !["frontmost", "sleep"].contains($0) }
        #expect(sequence == ["probe", "isHidden", "isMinimized", "activate", "raise", "setMain", "setFocused", "isFocused"])
    }

    @Test("hidden app and minimized window are restored before activation")
    @AXActor func unhideAndUnminimize() async {
        let port = MockFocusPort()
        port.hidden = true
        port.minimized = true
        let service = FocusService(port: port)
        _ = await service.focus(WindowSessionID())
        let unhideIndex = port.calls.firstIndex(of: "unhide")
        let unminimizeIndex = port.calls.firstIndex(of: "unminimize")
        let activateIndex = port.calls.firstIndex(of: "activate")
        #expect(unhideIndex != nil && unminimizeIndex != nil && activateIndex != nil)
        #expect(unhideIndex! < unminimizeIndex! && unminimizeIndex! < activateIndex!)
    }

    @Test("a dead target is refused without touching the app")
    @AXActor func deadTarget() async {
        let port = MockFocusPort(probeResults: [.windowGone])
        let service = FocusService(port: port)
        let outcome = await service.focus(WindowSessionID())
        #expect(outcome == .failed(.windowGone))
        #expect(!port.calls.contains("activate"))
        #expect(!port.calls.contains("raise"))
    }

    @Test("retries exactly once when verification fails")
    @AXActor func singleRetry() async {
        // frontmost never becomes the target; focus never confirms.
        let port = MockFocusPort(frontmost: Array(repeating: 77, count: 100), focusedResults: Array(repeating: false, count: 100))
        let service = FocusService(port: port)
        service.verificationAttempts = 2
        let outcome = await service.focus(WindowSessionID())
        #expect(port.calls.filter { $0 == "activate" }.count == 2)
        #expect(outcome == .failed(.activationRejected))
    }

    @Test("aborts instead of retrying when the user switched to a third app")
    @AXActor func abortOnUserSwitch() async {
        // baseline frontmost 77 (before), then during verification 77, then after first attempt the user is on 99.
        let port = MockFocusPort(frontmost: [77, 77, 77, 77, 99], focusedResults: Array(repeating: false, count: 100))
        let service = FocusService(port: port)
        service.verificationAttempts = 1
        let outcome = await service.focus(WindowSessionID())
        #expect(port.calls.filter { $0 == "activate" }.count == 1)
        if case .aborted = outcome {} else { Issue.record("expected abort, got \(outcome)") }
    }

    @Test("unsupported focus attribute falls back to main-window confirmation")
    @AXActor func unverifiedFallback() async {
        let port = MockFocusPort(frontmost: [500], focusedResults: Array(repeating: nil, count: 100))
        port.mainResult = true
        let service = FocusService(port: port)
        let outcome = await service.focus(WindowSessionID())
        if case .unverified = outcome {} else { Issue.record("expected unverified, got \(outcome)") }
    }

    @Test("raise failure while frontmost reports a raise problem")
    @AXActor func raiseFailure() async {
        let port = MockFocusPort(frontmost: Array(repeating: 500, count: 100), focusedResults: Array(repeating: false, count: 100))
        port.raiseResult = false
        let service = FocusService(port: port)
        service.verificationAttempts = 1
        let outcome = await service.focus(WindowSessionID())
        #expect(outcome == .failed(.raiseFailed))
    }
}
