import Testing
@testable import ContextDock

@Suite("Discovery suspension")
struct DiscoverySuspensionTests {
    @Test("overlapping reasons resume only after the final reason clears")
    func overlappingReasons() {
        var state = DiscoverySuspensionState()
        let firstSuspend = state.suspend(for: .screenLocked)
        let secondSuspend = state.suspend(for: .displaySleep)
        let firstResume = state.resume(from: .displaySleep)
        #expect(firstSuspend)
        #expect(!secondSuspend)
        #expect(!firstResume)
        #expect(state.isSuspended)
        let finalResume = state.resume(from: .screenLocked)
        #expect(finalResume)
        #expect(!state.isSuspended)
    }

    @Test("duplicate notifications are idempotent")
    func duplicateNotifications() {
        var state = DiscoverySuspensionState()
        let firstSuspend = state.suspend(for: .systemSleep)
        let duplicateSuspend = state.suspend(for: .systemSleep)
        let firstResume = state.resume(from: .systemSleep)
        let duplicateResume = state.resume(from: .systemSleep)
        #expect(firstSuspend)
        #expect(!duplicateSuspend)
        #expect(firstResume)
        #expect(!duplicateResume)
        #expect(!state.isSuspended)
    }

    @Test("an unrelated resume cannot clear another reason")
    func unrelatedResume() {
        var state = DiscoverySuspensionState()
        let suspended = state.suspend(for: .sessionInactive)
        let resumed = state.resume(from: .screenLocked)
        #expect(suspended)
        #expect(!resumed)
        #expect(state.reasons == [.sessionInactive])
    }
}
