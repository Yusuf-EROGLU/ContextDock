import Foundation
import Testing
@testable import ContextDock

@Suite("GitOutputParsers")
struct GitOutputParserTests {
    private func result(_ stdout: String = "", stderr: String = "", exit: Int32 = 0, timedOut: Bool = false, launchError: String? = nil) -> GitCommandResult {
        GitCommandResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut, truncated: false, launchError: launchError)
    }

    @Test func worktreePorcelain() {
        let text = "worktree /Users/me/Projects/game\0HEAD 1111111111111111111111111111111111111111\0branch refs/heads/main\0\0worktree /Users/me/Worktrees/game audio\0HEAD 2222222222222222222222222222222222222222\0detached\0\0"
        let entries = GitOutputParsers.parseWorktreeList(Data(text.utf8))
        #expect(entries.count == 2)
        #expect(entries[0] == WorktreeEntry(path: "/Users/me/Projects/game", head: "1111111111111111111111111111111111111111", branch: "main", isDetached: false, isBare: false))
        #expect(entries[1].path == "/Users/me/Worktrees/game audio")
        #expect(entries[1].isDetached)
        #expect(entries[1].branch == nil)
    }

    @Test func failureClassification() {
        #expect(GitOutputParsers.classifyFailure(result(stderr: "fatal: not a git repository (or any of the parent directories): .git", exit: 128)) == .notARepository)
        #expect(GitOutputParsers.classifyFailure(result(stderr: "fatal: detected dubious ownership in repository", exit: 128)) == .noAccess)
        #expect(GitOutputParsers.classifyFailure(result(launchError: "not found")) == .gitMissing)
        #expect(GitOutputParsers.classifyFailure(result(timedOut: true)) == .unknown(reason: "timed out"))
        if case .unknown = GitOutputParsers.classifyFailure(result(stderr: "something odd", exit: 2)) {} else { Issue.record("expected unknown") }
    }

    @Test func branchStates() {
        #expect(GitOutputParsers.branchState(symbolicRef: result("main\n"), revParse: result("abc1234\n")) == .init(branchName: "main", shortCommit: "abc1234", isDetached: false, isUnborn: false))
        #expect(GitOutputParsers.branchState(symbolicRef: result("", exit: 1), revParse: result("abc1234\n")) == .init(branchName: nil, shortCommit: "abc1234", isDetached: true, isUnborn: false))
        #expect(GitOutputParsers.branchState(symbolicRef: result("main\n"), revParse: result("", stderr: "fatal: ambiguous argument 'HEAD'", exit: 128)) == .init(branchName: "main", shortCommit: nil, isDetached: false, isUnborn: true))
    }

    @Test func environmentIsScrubbed() {
        let env = GitRunner.environment(base: ["GIT_DIR": "/x", "GIT_WORK_TREE": "/y", "PATH": "/usr/bin", "GIT_INDEX_FILE": "i"])
        #expect(env["GIT_DIR"] == nil)
        #expect(env["GIT_WORK_TREE"] == nil)
        #expect(env["GIT_INDEX_FILE"] == nil)
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    }
}

/// Real git in temporary repositories. Skipped when no git executable is available.
@Suite("GitService with temporary repositories", .serialized)
struct GitServiceTempRepoTests {
    let git: URL?
    let root: URL

    init() throws {
        git = GitExecutableLocator.locate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private var isolatedEnvironment: [String: String] {
        var env = GitRunner.environment(base: ["PATH": "/usr/bin:/bin"])
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["HOME"] = root.path
        return env
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) async throws -> GitCommandResult {
        let git = try #require(git)
        let base = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"]
        let result = await GitRunner.run(git: git, arguments: base + args, directory: dir, environment: isolatedEnvironment)
        #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.stderrText)")
        return result
    }

    private func makeService() throws -> GitService {
        let git = try #require(git)
        let env = isolatedEnvironment
        return GitService(gitURL: git, runner: { git, args, dir in
            await GitRunner.run(git: git, arguments: args, directory: dir, environment: env)
        })
    }

    private func makeRepo(named name: String) async throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await run(["init", "-q"], in: dir)
        return dir
    }

    private func commit(in dir: URL, file: String = "a.txt") async throws {
        try Data("x\n".utf8).write(to: dir.appendingPathComponent(file))
        try await run(["add", file], in: dir)
        try await run(["commit", "-q", "-m", "init"], in: dir)
    }

    @Test("normal repository with a Unicode + space path reports its branch")
    func normalRepository() async throws {
        defer { cleanup() }
        let repo = try await makeRepo(named: "Müzik Oyunu deneme")
        try await commit(in: repo)
        let service = try makeService()
        let info = await service.refresh(path: repo.path)
        #expect(info.status == .ok)
        #expect(info.branchName == "main")
        #expect(info.shortCommit?.count == 7)
        #expect(!info.isDetached && !info.isUnborn)
        #expect(PathNormalizer.normalize(info.worktreeRoot) == PathNormalizer.normalize(repo.path))
        #expect(info.repositoryRoot.map(PathNormalizer.normalize) == PathNormalizer.normalize(repo.path))
    }

    @Test("linked worktree keeps its own branch and shares the common dir")
    func linkedWorktree() async throws {
        defer { cleanup() }
        let repo = try await makeRepo(named: "game")
        try await commit(in: repo)
        let linked = root.appendingPathComponent("game audio wt", isDirectory: true)
        try await run(["worktree", "add", "-q", linked.path, "-b", "feature/audio"], in: repo)

        let service = try makeService()
        let mainInfo = await service.refresh(path: repo.path)
        let linkedInfo = await service.refresh(path: linked.path)
        #expect(mainInfo.branchName == "main")
        #expect(linkedInfo.branchName == "feature/audio")
        #expect(PathNormalizer.normalize(linkedInfo.worktreeRoot) == PathNormalizer.normalize(linked.path))
        #expect(linkedInfo.worktreeRoot != mainInfo.worktreeRoot)
        #expect(linkedInfo.commonDirectory == mainInfo.commonDirectory)
        #expect(linkedInfo.gitDirectory != mainInfo.gitDirectory)
        #expect(linkedInfo.repositoryRoot.map(PathNormalizer.normalize) == PathNormalizer.normalize(repo.path))

        // Switching the branch in one worktree must not leak into the other's cache.
        try await run(["checkout", "-q", "-b", "feature/other"], in: linked)
        let again = await service.refresh(path: linked.path)
        #expect(again.branchName == "feature/other")
        #expect(await service.refresh(path: repo.path).branchName == "main")

        let worktrees = await service.worktrees(for: repo.path)
        #expect(worktrees.count == 2)
    }

    @Test("detached HEAD shows commit, not a made-up branch")
    func detachedHead() async throws {
        defer { cleanup() }
        let repo = try await makeRepo(named: "detached")
        try await commit(in: repo)
        try await run(["checkout", "-q", "--detach"], in: repo)
        let info = await service_refresh(repo)
        #expect(info.status == .ok)
        #expect(info.isDetached)
        #expect(info.branchName == nil)
        #expect(info.shortCommit != nil)
    }

    @Test("repository without commits keeps its symbolic branch")
    func unbornBranch() async throws {
        defer { cleanup() }
        let repo = try await makeRepo(named: "empty")
        let info = await service_refresh(repo)
        #expect(info.status == .ok)
        #expect(info.isUnborn)
        #expect(info.branchName == "main")
        #expect(info.shortCommit == nil)
    }

    @Test("a folder that is not a repository is classified as such")
    func notARepository() async throws {
        defer { cleanup() }
        let dir = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info = await service_refresh(dir)
        #expect(info.status == .notARepository)
        #expect(info.branchName == nil)
    }

    @Test("missing folder is reported as no access")
    func missingFolder() async throws {
        defer { cleanup() }
        let info = await service_refresh(root.appendingPathComponent("does-not-exist"))
        #expect(info.status == .noAccess)
    }

    @Test("git missing is reported without running anything")
    func gitMissing() async {
        let service = GitService(gitURL: nil, runner: { _, _, _ in
            Issue.record("runner must not be called")
            return GitCommandResult(exitCode: nil, stdout: Data(), stderr: Data(), timedOut: false, truncated: false, launchError: "x")
        })
        let info = await service.refresh(path: root.path)
        #expect(info.status == .gitMissing)
    }

    @Test("a timed out branch query keeps the previous branch marked stale")
    func timeoutKeepsStale() async throws {
        defer { cleanup() }
        let repo = try await makeRepo(named: "stale")
        try await commit(in: repo)
        let git = try #require(git)
        let env = isolatedEnvironment
        let failNext = OSAllocatedUnfairLockBox(false)
        let service = GitService(gitURL: git, runner: { git, args, dir in
            if failNext.value, args.first == "symbolic-ref" {
                return GitCommandResult(exitCode: nil, stdout: Data(), stderr: Data(), timedOut: true, truncated: false, launchError: nil)
            }
            return await GitRunner.run(git: git, arguments: args, directory: dir, environment: env)
        })
        let first = await service.refresh(path: repo.path)
        #expect(first.branchName == "main")
        failNext.value = true
        let second = await service.refresh(path: repo.path)
        #expect(second.branchName == "main")
        #expect(second.isStale)
        #expect(second.status == .ok)
    }

    @Test("the runner enforces the timeout")
    func runnerTimeout() async throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let start = Date()
        let result = await GitRunner.runProcess(executable: sleep, arguments: ["5"], directory: root, timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("the runner caps output and terminates the process")
    func runnerOutputCap() async throws {
        let yes = URL(fileURLWithPath: "/usr/bin/yes")
        let result = await GitRunner.runProcess(executable: yes, arguments: [], directory: root, timeout: .seconds(3), outputCap: 4096)
        #expect(result.truncated)
        #expect(result.stdout.count <= 4096)
        #expect(!result.timedOut)
    }

    private func service_refresh(_ dir: URL) async -> GitInfo {
        guard let service = try? makeService() else {
            return .unavailable(path: dir.path, status: .gitMissing)
        }
        return await service.refresh(path: dir.path)
    }
}

/// Tiny lock box for test flags.
final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
