import Darwin
import Foundation

/// Reads a process start time through `sysctl(KERN_PROC_PID)`. Public API, no privileges.
enum ProcessStartTime {
    static func unixMilliseconds(pid: pid_t) -> Int64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
    }

    /// Kernel start time first, `launchDate` second, else nil.
    static func unixMilliseconds(pid: pid_t, launchDate: Date?) -> Int64? {
        if let ms = unixMilliseconds(pid: pid) { return ms }
        if let launchDate { return Int64(launchDate.timeIntervalSince1970 * 1000) }
        return nil
    }
}
