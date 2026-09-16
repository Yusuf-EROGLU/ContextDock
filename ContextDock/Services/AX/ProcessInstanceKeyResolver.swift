import Foundation

/// Maps running applications to `ProcessInstanceKey`s and detects PID reuse. Pure except for
/// the injected start-time lookup.
struct ProcessInstanceKeyResolver {
    struct Resolution: Equatable {
        let key: ProcessInstanceKey
        /// A previous key for the same pid that is now invalid (the pid was reused).
        let replaced: ProcessInstanceKey?
    }

    var startTime: (pid_t, Date?) -> Int64?
    private var keysByPid: [pid_t: ProcessInstanceKey] = [:]
    private var generation: UInt64 = 0

    init(startTime: @escaping (pid_t, Date?) -> Int64? = ProcessStartTime.unixMilliseconds(pid:launchDate:)) {
        self.startTime = startTime
    }

    var knownKeys: [ProcessInstanceKey] { Array(keysByPid.values) }

    func key(forPid pid: pid_t) -> ProcessInstanceKey? {
        keysByPid[pid]
    }

    mutating func resolve(pid: pid_t, launchDate: Date?) -> Resolution {
        let current = startTime(pid, launchDate)
        var replaced: ProcessInstanceKey?
        if let existing = keysByPid[pid] {
            switch (existing.start, current) {
            case (.unixMilliseconds(let known), .some(let now)) where known == now:
                return Resolution(key: existing, replaced: nil)
            case (.generation, .none):
                return Resolution(key: existing, replaced: nil)
            default:
                replaced = existing
            }
        }
        let key: ProcessInstanceKey
        if let current {
            key = ProcessInstanceKey(pid: pid, start: .unixMilliseconds(current))
        } else {
            generation += 1
            key = ProcessInstanceKey(pid: pid, start: .generation(generation))
        }
        keysByPid[pid] = key
        return Resolution(key: key, replaced: replaced)
    }

    mutating func forget(_ key: ProcessInstanceKey) {
        if keysByPid[key.pid] == key {
            keysByPid[key.pid] = nil
        }
    }

    mutating func forgetAll() {
        keysByPid.removeAll()
    }
}
