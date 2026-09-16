import Foundation

/// One entry of `git worktree list --porcelain -z`.
struct WorktreeEntry: Sendable, Hashable {
    var path: String
    var head: String?
    var branch: String?
    var isDetached: Bool
    var isBare: Bool
}

/// Pure parsing/classification of git output.
enum GitOutputParsers {
    /// Parses the NUL-terminated porcelain format: records are separated by an empty line
    /// (two NULs), attributes by single NULs.
    static func parseWorktreeList(_ data: Data) -> [WorktreeEntry] {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let entry = current { entries.append(entry) }
                current = nil
                continue
            }
            if field.hasPrefix("worktree ") {
                if let entry = current { entries.append(entry) }
                current = WorktreeEntry(path: String(field.dropFirst("worktree ".count)), head: nil, branch: nil, isDetached: false, isBare: false)
            } else if field.hasPrefix("HEAD ") {
                current?.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                var branch = String(field.dropFirst("branch ".count))
                if branch.hasPrefix("refs/heads/") { branch.removeFirst("refs/heads/".count) }
                current?.branch = branch
            } else if field == "detached" {
                current?.isDetached = true
            } else if field == "bare" {
                current?.isBare = true
            }
        }
        if let entry = current { entries.append(entry) }
        return entries
    }

    /// Distinguishes "not a repository" from "no access" from "unknown" for a failed command.
    static func classifyFailure(_ result: GitCommandResult) -> GitStatus {
        if result.launchError != nil { return .gitMissing }
        if result.timedOut { return .unknown(reason: "timed out") }
        let stderr = result.stderrText.lowercased()
        if stderr.contains("not a git repository") { return .notARepository }
        if stderr.contains("dubious ownership") || stderr.contains("permission denied") || stderr.contains("operation not permitted") {
            return .noAccess
        }
        if stderr.contains("no such file or directory") || stderr.contains("cannot change to") {
            return .noAccess
        }
        let firstLine = result.stderrText.split(separator: "\n").first.map(String.init) ?? "exit \(result.exitCode.map(String.init) ?? "?")"
        return .unknown(reason: String(firstLine.prefix(120)))
    }

    struct BranchState: Sendable, Equatable {
        var branchName: String?
        var shortCommit: String?
        var isDetached: Bool
        var isUnborn: Bool
    }

    /// Combines `symbolic-ref --quiet --short HEAD` and `rev-parse --short=7 HEAD`.
    /// - symbolic-ref exit 1 with empty output means detached HEAD.
    /// - rev-parse failing on an existing symbolic ref means an unborn branch (no commits).
    static func branchState(symbolicRef: GitCommandResult, revParse: GitCommandResult) -> BranchState {
        let branch = symbolicRef.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = revParse.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if symbolicRef.exitCode == 0, !branch.isEmpty {
            if revParse.exitCode == 0, !commit.isEmpty {
                return BranchState(branchName: branch, shortCommit: commit, isDetached: false, isUnborn: false)
            }
            return BranchState(branchName: branch, shortCommit: nil, isDetached: false, isUnborn: true)
        }
        if revParse.exitCode == 0, !commit.isEmpty {
            return BranchState(branchName: nil, shortCommit: commit, isDetached: true, isUnborn: false)
        }
        return BranchState(branchName: nil, shortCommit: nil, isDetached: false, isUnborn: false)
    }

    static func singleLine(_ result: GitCommandResult) -> String? {
        guard result.succeeded else { return nil }
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}
