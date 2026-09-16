import Foundation

/// Runs git only in user-attached or otherwise verified folders. Results are cached by
/// worktree root; identical in-flight queries are coalesced and at most two git processes run
/// at once. Failures keep the previous information, marked stale.
actor GitService {
    struct Entry: Sendable {
        var info: GitInfo
        var structureUpdatedAt: Date?
    }

    private let gitURL: URL?
    private let runner: @Sendable (URL, [String], URL) async -> GitCommandResult
    private let semaphore = AsyncSemaphore(value: 2)
    private var entriesByQueryPath: [String: Entry] = [:]
    private var inFlight: [String: Task<GitInfo, Never>] = [:]

    var structureRefreshInterval: TimeInterval = 60

    init(
        gitURL: URL? = GitExecutableLocator.locate(),
        runner: @escaping @Sendable (URL, [String], URL) async -> GitCommandResult = { git, args, dir in
            await GitRunner.run(git: git, arguments: args, directory: dir)
        }
    ) {
        self.gitURL = gitURL
        self.runner = runner
    }

    var isGitAvailable: Bool { gitURL != nil }

    func cached(for path: String) -> GitInfo? {
        entriesByQueryPath[PathNormalizer.normalize(path)]?.info
    }

    func forget(path: String) {
        entriesByQueryPath[PathNormalizer.normalize(path)] = nil
    }

    /// Refreshes the branch (and, when due, the repository structure) for a folder.
    func refresh(path rawPath: String, force: Bool = false) async -> GitInfo {
        let path = PathNormalizer.normalize(rawPath)
        if let running = inFlight[path] {
            return await running.value
        }
        let task = Task<GitInfo, Never> { [weak self] in
            guard let self else {
                return GitInfo.unavailable(path: path, status: .unknown(reason: "service gone"))
            }
            return await self.performRefresh(path: path, force: force)
        }
        inFlight[path] = task
        let info = await task.value
        inFlight[path] = nil
        return info
    }

    private func performRefresh(path: String, force: Bool) async -> GitInfo {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let now = Date()
        var entry = entriesByQueryPath[path] ?? Entry(info: .unavailable(path: path, status: .unknown(reason: "not queried yet")), structureUpdatedAt: nil)

        guard let gitURL else {
            entry.info = .unavailable(path: path, status: .gitMissing)
            entriesByQueryPath[path] = entry
            return entry.info
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            entry.info.status = .noAccess
            entry.info.isStale = true
            entry.info.lastUpdatedAt = now
            entriesByQueryPath[path] = entry
            return entry.info
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            entry.info.status = .noAccess
            entry.info.isStale = true
            entry.info.lastUpdatedAt = now
            entriesByQueryPath[path] = entry
            return entry.info
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let needsStructure = force || entry.structureUpdatedAt == nil
            || now.timeIntervalSince(entry.structureUpdatedAt!) > structureRefreshInterval
            || entry.info.status != .ok

        if needsStructure {
            let toplevel = await runner(gitURL, ["rev-parse", "--show-toplevel"], directory)
            guard toplevel.succeeded, let root = GitOutputParsers.singleLine(toplevel) else {
                let status = GitOutputParsers.classifyFailure(toplevel)
                switch status {
                case .notARepository, .noAccess, .gitMissing:
                    entry.info = .unavailable(path: path, status: status)
                    entry.structureUpdatedAt = now
                case .ok, .unknown:
                    entry.info.status = entry.info.status == .ok ? .ok : status
                    entry.info.isStale = true
                    entry.info.lastUpdatedAt = now
                }
                entriesByQueryPath[path] = entry
                return entry.info
            }
            entry.info.worktreeRoot = PathNormalizer.normalize(root)
            let gitDir = await runner(gitURL, ["rev-parse", "--absolute-git-dir"], directory)
            entry.info.gitDirectory = GitOutputParsers.singleLine(gitDir).map(PathNormalizer.normalize)
            let common = await runner(gitURL, ["rev-parse", "--path-format=absolute", "--git-common-dir"], directory)
            entry.info.commonDirectory = GitOutputParsers.singleLine(common).map(PathNormalizer.normalize)
            if let commonDirectory = entry.info.commonDirectory {
                // The main worktree owns the common dir; use its parent as the repository root.
                entry.info.repositoryRoot = commonDirectory.hasSuffix("/.git")
                    ? String(commonDirectory.dropLast("/.git".count))
                    : entry.info.worktreeRoot
            } else {
                entry.info.repositoryRoot = entry.info.worktreeRoot
            }
            entry.structureUpdatedAt = now
        }

        let symbolicRef = await runner(gitURL, ["symbolic-ref", "--quiet", "--short", "HEAD"], directory)
        let revParse = await runner(gitURL, ["rev-parse", "--short=7", "HEAD"], directory)

        if symbolicRef.timedOut || revParse.timedOut || symbolicRef.launchError != nil || revParse.launchError != nil {
            entry.info.isStale = true
            entry.info.lastUpdatedAt = now
            if entry.info.status != .ok {
                entry.info.status = GitOutputParsers.classifyFailure(symbolicRef.timedOut ? symbolicRef : revParse)
            }
            entriesByQueryPath[path] = entry
            return entry.info
        }

        let state = GitOutputParsers.branchState(symbolicRef: symbolicRef, revParse: revParse)
        if state.branchName == nil && state.shortCommit == nil {
            let status = GitOutputParsers.classifyFailure(symbolicRef.exitCode == 0 ? revParse : symbolicRef)
            if case .unknown = status, symbolicRef.exitCode == 1, revParse.exitCode != 0 {
                // symbolic-ref exit 1 with no output and no commit: treat as unborn detached state.
                entry.info.branchName = nil
                entry.info.shortCommit = nil
                entry.info.isDetached = true
                entry.info.isUnborn = true
                entry.info.status = .ok
            } else {
                entry.info.status = status
                entry.info.isStale = status == .unknown(reason: "") ? true : false
            }
        } else {
            entry.info.branchName = state.branchName
            entry.info.shortCommit = state.shortCommit
            entry.info.isDetached = state.isDetached
            entry.info.isUnborn = state.isUnborn
            entry.info.status = .ok
            entry.info.isStale = false
        }
        entry.info.lastUpdatedAt = now
        entriesByQueryPath[path] = entry
        return entry.info
    }

    /// Lists worktrees of the repository containing `path` (structure only; rarely needed).
    func worktrees(for rawPath: String) async -> [WorktreeEntry] {
        guard let gitURL else { return [] }
        let directory = URL(fileURLWithPath: PathNormalizer.normalize(rawPath), isDirectory: true)
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        let result = await runner(gitURL, ["worktree", "list", "--porcelain", "-z"], directory)
        guard result.succeeded else { return [] }
        return GitOutputParsers.parseWorktreeList(result.stdout)
    }
}

extension GitInfo {
    static func unavailable(path: String, status: GitStatus, now: Date = Date()) -> GitInfo {
        GitInfo(
            worktreeRoot: path,
            repositoryRoot: nil,
            gitDirectory: nil,
            commonDirectory: nil,
            branchName: nil,
            shortCommit: nil,
            isDetached: false,
            isUnborn: false,
            status: status,
            lastUpdatedAt: now,
            isStale: false
        )
    }
}
