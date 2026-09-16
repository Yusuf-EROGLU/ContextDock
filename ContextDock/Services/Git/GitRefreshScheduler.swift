import Foundation

/// Periodically refreshes Git information for the trusted project paths currently shown.
/// Branch info refreshes every few seconds while the bar is visible, less often when hidden;
/// repository structure refreshes rarely (handled inside `GitService`).
@MainActor
final class GitRefreshScheduler {
    var visibleInterval: Duration = .seconds(5)
    var hiddenInterval: Duration = .seconds(30)

    private let service: GitService
    private let store: WindowStore
    private var loop: Task<Void, Never>?
    private var isPaused = false
    private var isBarVisible = true
    private var knownPaths: Set<String> = []

    init(service: GitService, store: WindowStore) {
        self.service = service
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused {
                    await self.refreshAll()
                }
                let interval = self.isBarVisible ? self.visibleInterval : self.hiddenInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func setBarVisible(_ visible: Bool) {
        isBarVisible = visible
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused {
            Task { await refreshAll() }
        }
    }

    /// Called when the set of trusted project paths may have changed (new binding).
    func pathsMayHaveChanged() {
        let paths = store.trustedProjectPaths
        let added = paths.subtracting(knownPaths)
        knownPaths = paths
        guard !added.isEmpty else { return }
        Task { await refresh(paths: added, force: true) }
    }

    func refreshAll() async {
        let paths = store.trustedProjectPaths
        knownPaths = paths
        await refresh(paths: paths, force: false)
    }

    private func refresh(paths: Set<String>, force: Bool) async {
        guard !paths.isEmpty else { return }
        await withTaskGroup(of: (String, GitInfo).self) { group in
            for path in paths {
                group.addTask { [service] in
                    (path, await service.refresh(path: path, force: force))
                }
            }
            for await (path, info) in group {
                store.setGitInfo(info, for: path)
            }
        }
    }
}
