import Testing
@testable import ContextDock

@Suite("AX observation registry", .serialized)
struct AXObserverRegistryTests {
    @Test("unregistered token ids make late callbacks inert")
    @AXActor func unregisterMakesLateCallbackInert() {
        let control = MainActorAppControl(
            runningApps: { [] },
            activate: { _ in false },
            unhide: { _ in false }
        )
        let worker = AXWorker(control: control)
        let key = ProcessInstanceKey(pid: 123, start: .generation(1))
        let token = AXObservationToken(process: key, window: WindowSessionID(), worker: worker)

        let id = AXObservationRegistry.register(token)
        #expect(AXObservationRegistry.isRegistered(id))
        AXObservationRegistry.unregister(id)
        #expect(!AXObservationRegistry.isRegistered(id))

        // This follows the real callback path and must simply ignore the retired token id.
        AXObservationRegistry.dispatch(id: id, notification: AXNotificationName.elementDestroyed)
    }
}
