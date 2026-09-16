import Foundation

/// Minimal counting semaphore for structured concurrency.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        available = value
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
