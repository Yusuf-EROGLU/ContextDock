import Foundation
import os

/// Result of one git subprocess.
struct GitCommandResult: Sendable {
    var exitCode: Int32?
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var truncated: Bool
    var launchError: String?

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }
}

/// Runs git with an explicit argument vector (never a shell string), a scrubbed environment,
/// a timeout and an output cap. Stdout and stderr are drained concurrently so a chatty
/// command cannot deadlock on a full pipe.
enum GitRunner {
    static let defaultTimeout: Duration = .seconds(4)
    static let defaultOutputCap = 64 * 1024

    /// Environment variables that can redirect git to another repository or index.
    static let scrubbedEnvironmentKeys: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR",
    ]

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !scrubbedEnvironmentKeys.contains($0.key) }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        env["LC_ALL"] = "C"
        return env
    }

    private static let queue = DispatchQueue(label: "com.yusuferoglu.ContextDock.git", qos: .utility, attributes: .concurrent)

    static func run(
        git: URL,
        arguments: [String],
        directory: URL,
        timeout: Duration = defaultTimeout,
        outputCap: Int = defaultOutputCap,
        environment: [String: String]? = nil
    ) async -> GitCommandResult {
        await runProcess(
            executable: git,
            arguments: ["-C", directory.path] + arguments,
            directory: directory,
            timeout: timeout,
            outputCap: outputCap,
            environment: environment
        )
    }

    /// Generic subprocess runner used by `run(git:…)`; exposed for tests of the timeout/cap logic.
    static func runProcess(
        executable: URL,
        arguments: [String],
        directory: URL,
        timeout: Duration = defaultTimeout,
        outputCap: Int = defaultOutputCap,
        environment: [String: String]? = nil
    ) async -> GitCommandResult {
        let env = environment ?? Self.environment()
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = runBlocking(executable: executable, arguments: arguments, directory: directory, timeout: timeout, outputCap: outputCap, environment: env)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runBlocking(
        executable: URL,
        arguments: [String],
        directory: URL,
        timeout: Duration,
        outputCap: Int,
        environment: [String: String]
    ) -> GitCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: directory.path) ? directory : URL(fileURLWithPath: "/")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return GitCommandResult(exitCode: nil, stdout: Data(), stderr: Data(), timedOut: false, truncated: false, launchError: error.localizedDescription)
        }

        let pid = process.processIdentifier
        let state = OSAllocatedUnfairLock(initialState: (finished: false, timedOut: false))
        let killer = DispatchWorkItem {
            let shouldKill = state.withLock { s -> Bool in
                if s.finished { return false }
                s.timedOut = true
                return true
            }
            guard shouldKill else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) {
                if !state.withLock({ $0.finished }) { kill(pid, SIGKILL) }
            }
        }
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)

        let group = DispatchGroup()
        let stdoutBox = OSAllocatedUnfairLock(initialState: (data: Data(), truncated: false))
        let stderrBox = OSAllocatedUnfairLock(initialState: (data: Data(), truncated: false))

        func drain(_ handle: FileHandle, into box: OSAllocatedUnfairLock<(data: Data, truncated: Bool)>) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    let exceeded = box.withLock { s -> Bool in
                        guard !s.truncated else { return false }
                        s.data.append(chunk)
                        if s.data.count > outputCap {
                            s.data = s.data.prefix(outputCap)
                            s.truncated = true
                            return true
                        }
                        return false
                    }
                    if exceeded { kill(pid, SIGTERM) }
                }
            }
        }
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
        drain(stderrPipe.fileHandleForReading, into: stderrBox)

        process.waitUntilExit()
        state.withLock { $0.finished = true }
        killer.cancel()
        group.wait()

        let out = stdoutBox.withLock { $0 }
        let err = stderrBox.withLock { $0 }
        let timedOut = state.withLock { $0.timedOut }
        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: out.data,
            stderr: err.data,
            timedOut: timedOut,
            truncated: out.truncated || err.truncated,
            launchError: nil
        )
    }
}
