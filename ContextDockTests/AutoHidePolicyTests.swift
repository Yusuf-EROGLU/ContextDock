import Foundation
import Testing
@testable import ContextDock

@Suite("AutoHidePolicy")
struct AutoHidePolicyTests {
    @Test func collapsesAfterDelay() {
        let policy = AutoHidePolicy(delay: 5)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!policy.shouldCollapse(now: start.addingTimeInterval(4.9), lastInside: start, blocked: false))
        #expect(policy.shouldCollapse(now: start.addingTimeInterval(5), lastInside: start, blocked: false))
    }

    @Test func blockersPreventCollapse() {
        let policy = AutoHidePolicy(delay: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!policy.shouldCollapse(now: start.addingTimeInterval(60), lastInside: start, blocked: true))
    }
}
