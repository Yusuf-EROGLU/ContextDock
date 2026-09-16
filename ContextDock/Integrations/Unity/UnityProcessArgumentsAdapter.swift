import Darwin
import Foundation

/// Reads a process's argument vector through `sysctl(KERN_PROCARGS2)` and extracts Unity's
/// `-projectPath`. Public API, same-user processes only, no privilege escalation. Any failure
/// or ambiguity yields `nil` so the manual binding path takes over.
enum UnityProcessArgumentsAdapter {
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Data(buffer.prefix(size)))
    }

    /// Layout: Int32 argc, executable path, NUL padding, then argc NUL-terminated arguments.
    static func parseProcArgs(_ data: Data) -> [String]? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var index = data.startIndex + MemoryLayout<Int32>.size
        // Skip executable path.
        while index < data.endIndex, data[index] != 0 { index += 1 }
        // Skip padding NULs.
        while index < data.endIndex, data[index] == 0 { index += 1 }
        var args: [String] = []
        var current = Data()
        while index < data.endIndex, args.count < Int(argc) {
            let byte = data[index]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return args
    }

    /// Finds `-projectPath <path>` or `-projectPath=<path>` (case-insensitive flag).
    static func projectPath(in arguments: [String]) -> String? {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            let lower = argument.lowercased()
            if lower == "-projectpath" {
                if let next = iterator.next(), !next.isEmpty, !next.hasPrefix("-") { return next }
                return nil
            }
            if lower.hasPrefix("-projectpath=") {
                let value = String(argument.dropFirst("-projectpath=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func hint(pid: pid_t) -> ProcessArgumentsHint? {
        guard let args = arguments(pid: pid), let path = projectPath(in: args) else { return nil }
        let url = URL(fileURLWithPath: path)
        let validation = ProjectFolderValidator.validate(url)
        return ProcessArgumentsHint(projectPath: url.path, validation: validation)
    }
}
