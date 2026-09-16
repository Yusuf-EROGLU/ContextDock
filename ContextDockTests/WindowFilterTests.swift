import Testing
@testable import ContextDock

@Suite("WindowFilter")
struct WindowFilterTests {
    @Test func standardWindowsAreIncluded() {
        #expect(WindowFilter.decide(role: "AXWindow", subrole: "AXStandardWindow") == .include)
    }

    @Test("missing or unknown subrole is treated as a standard window")
    func missingSubrole() {
        #expect(WindowFilter.decide(role: "AXWindow", subrole: nil) == .include)
        #expect(WindowFilter.decide(role: "AXWindow", subrole: "") == .include)
        #expect(WindowFilter.decide(role: "AXWindow", subrole: "AXUnknown") == .include)
    }

    @Test func dialogsAreAuxiliary() {
        #expect(WindowFilter.decide(role: "AXWindow", subrole: "AXDialog") == .includeAsAuxiliary)
        #expect(WindowFilter.decide(role: "AXWindow", subrole: "AXFloatingWindow") == .includeAsAuxiliary)
        #expect(WindowFilter.shouldTrack(role: "AXWindow", subrole: "AXDialog", showAuxiliary: false) == false)
        #expect(WindowFilter.shouldTrack(role: "AXWindow", subrole: "AXDialog", showAuxiliary: true) == true)
    }

    @Test func nonWindowRolesAreExcluded() {
        #expect(WindowFilter.shouldTrack(role: "AXSheet", subrole: nil, showAuxiliary: true) == false)
        #expect(WindowFilter.shouldTrack(role: "AXMenu", subrole: nil, showAuxiliary: true) == false)
        #expect(WindowFilter.shouldTrack(role: nil, subrole: nil, showAuxiliary: true) == false)
    }

    @Test("matching in WindowMatcher never crosses claimed elements")
    func matcherClaimsOnce() {
        let a = WindowSessionID(), b = WindowSessionID()
        let outcome = WindowMatcher.match(
            tracked: [(id: a, element: IntElement(id: 1)), (id: b, element: IntElement(id: 1))],
            fresh: [IntElement(id: 1), IntElement(id: 3)]
        )
        #expect(outcome.matched == [a: 0])
        #expect(outcome.missing == [b])
        #expect(outcome.unmatchedFresh == [1])
    }
}
