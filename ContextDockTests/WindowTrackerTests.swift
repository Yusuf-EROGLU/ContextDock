import Foundation
import Testing
@testable import ContextDock

@Suite("WindowTracker identity")
struct WindowTrackerTests {
    private func makeTracker() -> (WindowTracker<IntElement>, SequenceCounter) {
        (WindowTracker<IntElement>(process: .test()), SequenceCounter())
    }

    @Test("same elements keep the same session ids across scans")
    func stableIdentity() {
        var (tracker, seq) = makeTracker()
        let first = tracker.apply(.success([(IntElement(id: 1), .window("A")), (IntElement(id: 2), .window("B"))]), nextSequence: seq.next, probe: { _ in .alive })
        #expect(first.added.count == 2)
        let idsBefore = tracker.snapshots.map(\.id)

        let second = tracker.apply(.success([(IntElement(id: 2), .window("B")), (IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .alive })
        #expect(second == WindowTracker<IntElement>.Changes())
        #expect(tracker.snapshots.map(\.id) == idsBefore, "order and ids are stable regardless of listing order")
    }

    @Test("a title change updates the title but not the id or sequence")
    func titleChangeKeepsIdentity() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 7), .window("Old"))]), nextSequence: seq.next, probe: { _ in .alive })
        let before = tracker.snapshots[0]

        _ = tracker.apply(.success([(IntElement(id: 7), .window("New"))]), nextSequence: seq.next, probe: { _ in .alive })
        let after = tracker.snapshots[0]
        #expect(after.id == before.id)
        #expect(after.firstSeenSequence == before.firstSeenSequence)
        #expect(after.title == "New")

        tracker.updateTitle(before.id, title: "Newer")
        #expect(tracker.snapshots[0].title == "Newer")
        #expect(tracker.snapshots[0].id == before.id)
    }

    @Test("two windows with identical titles get distinct ids")
    func identicalTitlesStayDistinct() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 1), .window("Same")), (IntElement(id: 2), .window("Same"))]), nextSequence: seq.next, probe: { _ in .alive })
        let ids = Set(tracker.snapshots.map(\.id))
        #expect(ids.count == 2)
        #expect(tracker.snapshots.map(\.firstSeenSequence) == [1, 2])
    }

    @Test("a failed scan marks windows stale and removes nothing")
    func failureKeepsWindowsStale() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .alive })
        let changes = tracker.apply(.failure, nextSequence: seq.next, probe: { _ in .dead })
        #expect(changes.removed.isEmpty)
        #expect(tracker.snapshots.count == 1)
        #expect(tracker.snapshots[0].isStale)

        _ = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .alive })
        #expect(!tracker.snapshots[0].isStale)
    }

    @Test("a window missing from two successful scans is removed only when the probe says dead")
    func removalNeedsEvidence() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 1), .window("A")), (IntElement(id: 2), .window("B"))]), nextSequence: seq.next, probe: { _ in .alive })
        let idB = tracker.snapshots[1].id

        var changes = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .dead })
        #expect(changes.removed.isEmpty, "one missed scan is not enough")
        #expect(tracker.snapshots.count == 2)

        changes = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .alive })
        #expect(changes.removed.isEmpty, "element still answers: keep it, flag as unlisted")
        #expect(tracker.snapshots.first { $0.id == idB }?.listedByApplication == false)

        changes = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .dead })
        #expect(changes.removed == [idB])
        #expect(tracker.snapshots.count == 1)
    }

    @Test("a not-responding probe keeps the window and marks it stale")
    func notRespondingProbe() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 1), .window("A"))]), nextSequence: seq.next, probe: { _ in .alive })
        _ = tracker.apply(.success([]), nextSequence: seq.next, probe: { _ in .notResponding })
        let changes = tracker.apply(.success([]), nextSequence: seq.next, probe: { _ in .notResponding })
        #expect(changes.removed.isEmpty)
        #expect(tracker.snapshots[0].isStale)
    }

    @Test("new windows are appended in first-seen order")
    func firstSeenOrder() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 5), .window("E"))]), nextSequence: seq.next, probe: { _ in .alive })
        _ = tracker.apply(.success([(IntElement(id: 1), .window("A")), (IntElement(id: 5), .window("E"))]), nextSequence: seq.next, probe: { _ in .alive })
        #expect(tracker.snapshots.map(\.title) == ["E", "A"])
    }

    @Test("focus flag follows the focused element")
    func focusFlag() {
        var (tracker, seq) = makeTracker()
        _ = tracker.apply(.success([(IntElement(id: 1), .window("A")), (IntElement(id: 2), .window("B"))]), nextSequence: seq.next, probe: { _ in .alive })
        tracker.setFocused(IntElement(id: 2))
        #expect(tracker.snapshots.map(\.isFocused) == [false, true])
        tracker.setFocused(nil)
        #expect(tracker.snapshots.map(\.isFocused) == [false, false])
    }
}

@Suite("ProcessInstanceKeyResolver")
struct ProcessInstanceKeyResolverTests {
    @Test("same pid with the same start time resolves to the same key")
    func stableKey() {
        var resolver = ProcessInstanceKeyResolver(startTime: { _, _ in 5_000 })
        let a = resolver.resolve(pid: 42, launchDate: nil)
        let b = resolver.resolve(pid: 42, launchDate: nil)
        #expect(a.key == b.key)
        #expect(b.replaced == nil)
    }

    @Test("pid reuse with a new start time yields a new key and reports the old one")
    func pidReuse() {
        var start: Int64 = 5_000
        var resolver = ProcessInstanceKeyResolver(startTime: { _, _ in start })
        let first = resolver.resolve(pid: 42, launchDate: nil)
        start = 9_000
        let second = resolver.resolve(pid: 42, launchDate: nil)
        #expect(second.key != first.key)
        #expect(second.replaced == first.key)
        #expect(resolver.key(forPid: 42) == second.key)
    }

    @Test("falls back to a generation counter when no start time is available")
    func generationFallback() {
        var resolver = ProcessInstanceKeyResolver(startTime: { _, _ in nil })
        let a = resolver.resolve(pid: 1, launchDate: nil)
        let b = resolver.resolve(pid: 2, launchDate: nil)
        #expect(a.key.start == .generation(1))
        #expect(b.key.start == .generation(2))
        #expect(resolver.resolve(pid: 1, launchDate: nil).key == a.key)
    }

    @Test("launch date is used when the kernel start time is missing")
    func launchDateFallback() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let ms = ProcessStartTime.unixMilliseconds(pid: -1, launchDate: date)
        #expect(ms == 1_700_000_000_000)
    }

    @Test("the real kernel start time is readable for this process")
    func kernelStartTime() {
        let ms = ProcessStartTime.unixMilliseconds(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(ms != nil)
        #expect((ms ?? 0) > 1_600_000_000_000)
    }
}
