import Foundation
import os

/// A `SerialExecutor` backed by a dedicated thread that runs a `CFRunLoop`. Jobs are executed
/// on that thread, so actor code using this executor can add run loop sources (for example
/// `AXObserver` sources) to `CFRunLoopGetCurrent()` and receive their callbacks on the same
/// thread between jobs.
///
/// The executor stores its run loop as the integer address of a retained CF reference, which is
/// trivially `Sendable`, so the class needs no unchecked conformance. The thread lives for the
/// lifetime of the process.
final class RunLoopExecutor: SerialExecutor {
    private let loopAddress: UInt

    init(label: String, qualityOfService: QualityOfService = .userInitiated) {
        let ready = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<UInt>(initialState: 0)

        let thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            // A far-future timer keeps CFRunLoopRun from returning while no sources are attached.
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTime.greatestFiniteMagnitude,
                CFAbsoluteTime.greatestFiniteMagnitude,
                0,
                0
            ) { _ in }
            CFRunLoopAddTimer(loop, keepAlive, .defaultMode)
            let address = UInt(bitPattern: Unmanaged.passRetained(loop).toOpaque())
            box.withLock { $0 = address }
            ready.signal()
            while true {
                CFRunLoopRun()
            }
        }
        thread.name = label
        thread.qualityOfService = qualityOfService
        thread.start()
        ready.wait()
        loopAddress = box.withLock { $0 }
        precondition(loopAddress != 0, "run loop thread failed to start")
    }

    private var runLoop: CFRunLoop {
        Unmanaged<CFRunLoop>.fromOpaque(UnsafeRawPointer(bitPattern: loopAddress)!).takeUnretainedValue()
    }

    /// `true` when called from the executor's thread.
    var isCurrent: Bool {
        CFRunLoopGetCurrent() == runLoop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedSerialExecutor()
        let loop = runLoop
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            unownedJob.runSynchronously(on: unownedExecutor)
        }
        CFRunLoopWakeUp(loop)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    @available(macOS 15.0, *)
    func checkIsolated() {
        precondition(isCurrent, "Expected to run on \(Thread.current.name ?? "executor thread")")
    }
}
