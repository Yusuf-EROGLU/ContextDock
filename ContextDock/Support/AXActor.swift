import Foundation

/// Global actor for every type that touches `AXUIElement`/`AXObserver`. Its executor is a
/// dedicated thread with a live run loop, so AX observer callbacks are delivered there and
/// AX IPC never blocks the main thread. CF references stay confined to this actor.
@globalActor
actor AXActor: GlobalActor {
    static let shared = AXActor()

    private nonisolated let runLoopExecutor = RunLoopExecutor(label: "com.yusuferoglu.ContextDock.ax-worker")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        runLoopExecutor.asUnownedSerialExecutor()
    }

    private init() {}
}
