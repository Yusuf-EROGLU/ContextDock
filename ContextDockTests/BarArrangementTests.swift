import Foundation
import Testing
@testable import ContextDock

@Suite("BarArrangement")
struct BarArrangementTests {
    let a = WindowSessionID(), b = WindowSessionID(), c = WindowSessionID(), d = WindowSessionID()

    private func arranged() -> BarArrangement {
        var arrangement = BarArrangement()
        arrangement.sync(windowsInFirstSeenOrder: [a, b, c, d])
        return arrangement
    }

    @Test("windows appear in first-seen order and vanish when closed")
    func syncOrder() {
        var arrangement = arranged()
        #expect(arrangement.order == [.window(a), .window(b), .window(c), .window(d)])
        arrangement.sync(windowsInFirstSeenOrder: [a, c, d])
        #expect(arrangement.order == [.window(a), .window(c), .window(d)])
        let e = WindowSessionID()
        arrangement.sync(windowsInFirstSeenOrder: [a, c, d, e])
        #expect(arrangement.order.last == .window(e))
    }

    @Test("stacking a window onto another creates a group in the target's slot")
    func stackCreatesGroup() {
        var arrangement = arranged()
        let groupID = arrangement.stack(.window(d), onto: .window(b))
        #expect(groupID != nil)
        #expect(arrangement.order == [.window(a), .group(groupID!), .window(c)])
        #expect(arrangement.group(groupID!)?.members == [b, d])

        arrangement.stack(.window(a), onto: .group(groupID!))
        #expect(arrangement.order == [.group(groupID!), .window(c)])
        #expect(arrangement.group(groupID!)?.members == [b, d, a])
    }

    @Test("stacking onto itself or its own group is a no-op")
    func stackNoop() {
        var arrangement = arranged()
        let before = arrangement
        #expect(arrangement.stack(.window(a), onto: .window(a)) == nil)
        #expect(arrangement == before)
    }

    @Test("groups dissolve when they fall to one member")
    func dissolve() {
        var arrangement = arranged()
        let groupID = arrangement.stack(.window(b), onto: .window(a))!
        arrangement.sync(windowsInFirstSeenOrder: [a, c, d])
        #expect(arrangement.group(groupID) == nil)
        #expect(arrangement.order == [.window(a), .window(c), .window(d)])
    }

    @Test("removing a member places it right after the group; ungroup expands in place")
    func removeAndUngroup() {
        var arrangement = arranged()
        let groupID = arrangement.stack(.window(c), onto: .window(a))!
        arrangement.stack(.window(d), onto: .group(groupID))
        arrangement.removeFromGroup(c)
        #expect(arrangement.order == [.group(groupID), .window(c), .window(b)])
        #expect(arrangement.group(groupID)?.members == [a, d])

        arrangement.ungroup(groupID)
        #expect(arrangement.order == [.window(a), .window(d), .window(c), .window(b)])
        #expect(arrangement.groupList.isEmpty)
    }

    @Test("move reorders items; moving a grouped window pulls it out")
    func move() {
        var arrangement = arranged()
        arrangement.move(.window(d), before: .window(a))
        #expect(arrangement.order == [.window(d), .window(a), .window(b), .window(c)])
        arrangement.move(.window(d), before: nil)
        #expect(arrangement.order == [.window(a), .window(b), .window(c), .window(d)])

        let groupID = arrangement.stack(.window(b), onto: .window(a))!
        arrangement.stack(.window(c), onto: .group(groupID))
        arrangement.move(.window(c), before: .group(groupID))
        #expect(arrangement.order == [.window(c), .group(groupID), .window(d)])
        #expect(arrangement.group(groupID)?.members == [a, b])
    }

    @Test("merging groups keeps the destination and appends members")
    func mergeGroups() {
        var arrangement = arranged()
        let first = arrangement.stack(.window(b), onto: .window(a))!
        let second = arrangement.stack(.window(d), onto: .window(c))!
        #expect(arrangement.stack(.group(first), onto: .group(second)) == second)
        #expect(arrangement.group(first) == nil)
        #expect(arrangement.group(second)?.members == [c, d, a, b])
        #expect(arrangement.order == [.group(second)])
    }

    @Test("stacking a group onto a window puts the window first")
    func groupOntoWindow() {
        var arrangement = arranged()
        let groupID = arrangement.stack(.window(b), onto: .window(a))!
        let merged = arrangement.stack(.group(groupID), onto: .window(d))!
        #expect(arrangement.group(merged)?.members == [d, a, b])
        #expect(arrangement.order == [.window(c), .group(merged)])
    }

    @Test("focus target is the last focused member, else the first")
    func focusTarget() {
        var arrangement = arranged()
        let groupID = arrangement.stack(.window(b), onto: .window(a))!
        #expect(arrangement.group(groupID)?.focusTarget == a)
        arrangement.noteFocused(b)
        #expect(arrangement.group(groupID)?.focusTarget == b)
        arrangement.sync(windowsInFirstSeenOrder: [a, c, d])
        #expect(arrangement.group(groupID) == nil, "one member left: dissolved")
    }
}
