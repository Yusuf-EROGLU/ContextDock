import AppKit

/// Pure matching of remembered windows to live ones. Preference order:
/// 1. same process instance (pid + start time) and same title,
/// 2. same app and same title,
/// 3. the only remaining window of that app,
/// 4. remaining windows of that app in order.
enum FingerprintMatcher {
    struct Candidate: Sendable, Hashable {
        var id: WindowSessionID
        var fingerprint: WindowFingerprint
        var order: UInt64
    }

    static func match(pending: [PersistedWindow], candidates: [Candidate]) -> [UUID: WindowSessionID] {
        var result: [UUID: WindowSessionID] = [:]
        var freeCandidates = candidates.sorted { $0.order < $1.order }
        var freePending = pending

        func appKey(_ fingerprint: WindowFingerprint) -> String {
            fingerprint.bundleIdentifier ?? "name:\(fingerprint.applicationName)"
        }

        func take(where predicate: (PersistedWindow, Candidate) -> Bool) {
            for record in freePending {
                guard let index = freeCandidates.firstIndex(where: { predicate(record, $0) }) else { continue }
                result[record.id] = freeCandidates[index].id
                freeCandidates.remove(at: index)
            }
            freePending.removeAll { result[$0.id] != nil }
        }

        // 1. Same process instance and title.
        take { record, candidate in
            guard let pid = record.fingerprint.pid, let start = record.fingerprint.processStartUnixMs else { return false }
            return candidate.fingerprint.pid == pid && candidate.fingerprint.processStartUnixMs == start
                && candidate.fingerprint.title == record.fingerprint.title
        }
        // 2. Same app and title.
        take { record, candidate in
            appKey(record.fingerprint) == appKey(candidate.fingerprint) && candidate.fingerprint.title == record.fingerprint.title
                && record.fingerprint.title != nil
        }
        // 3. The only remaining window of that app.
        for record in freePending {
            let key = appKey(record.fingerprint)
            let sameAppPending = freePending.filter { appKey($0.fingerprint) == key }
            let sameAppCandidates = freeCandidates.filter { appKey($0.fingerprint) == key }
            if sameAppPending.count == 1, sameAppCandidates.count == 1, let candidate = sameAppCandidates.first {
                result[record.id] = candidate.id
                freeCandidates.removeAll { $0.id == candidate.id }
            }
        }
        freePending.removeAll { result[$0.id] != nil }
        // 4. Remaining windows of the same app, in order.
        take { record, candidate in appKey(record.fingerprint) == appKey(candidate.fingerprint) }
        return result
    }
}

/// Remembers names, badges and groups across launches and re-attaches them to matching
/// windows. Records are dropped when their window closes while ContextDock is running (unless
/// the system is shutting down) or when the user removes the customization.
@MainActor
final class SessionMemory {
    /// How long after launch remembered windows may still be matched to new windows.
    var restoreWindow: TimeInterval = 15 * 60
    /// How long a window that vanished while running may come back (apps re-creating their
    /// windows after sleep, a quick relaunch) before its record is treated as closed for good.
    var lostGrace: TimeInterval = 120

    private let store: WindowStore
    private let persistence: PersistenceService
    private let launchedAt = Date()

    /// Persisted record id for each live window that carries a customization or group.
    private var binding: [WindowSessionID: UUID] = [:]
    /// Records from the previous run that have not been matched yet, plus records of windows
    /// that vanished recently (see `lostAt`).
    private var pendingWindows: [PersistedWindow]
    private var pendingGroups: [PersistedGroup]
    private var lostAt: [UUID: Date] = [:]
    /// Set during logout/shutdown: windows vanish because the session ends, not because the
    /// user closed them, so their records must survive.
    private(set) var isFrozen = false
    private var isSyncing = false

    init(store: WindowStore, persistence: PersistenceService) {
        self.store = store
        self.persistence = persistence
        pendingWindows = persistence.state.windows
        pendingGroups = persistence.state.groups
    }

    func freeze() {
        isFrozen = true
    }

    var pendingCount: Int { pendingWindows.count }

    /// Call after every store change: prunes closed windows, restores pending records, and
    /// rewrites the persisted state from the live one.
    func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        pruneClosedWindows()
        restorePending()
        if !isFrozen {
            save()
        }
    }

    func forgetEverything() {
        binding.removeAll()
        pendingWindows.removeAll()
        pendingGroups.removeAll()
        lostAt.removeAll()
        persistence.update { $0.windows = []; $0.groups = [] }
    }

    // MARK: - Steps

    /// Handles windows that disappeared. Their records (and their groups) are kept as pending
    /// for `lostGrace`, so a window an app re-creates comes back with its name and group; after
    /// that they count as closed by the user and are dropped. While frozen (shutdown) nothing is
    /// saved, so records survive untouched for the next launch.
    private func pruneClosedWindows() {
        let live = Set(store.snapshot.windows.map(\.id))
        let closed = binding.filter { !live.contains($0.key) }
        guard !closed.isEmpty else { return }
        let savedWindows = Dictionary(uniqueKeysWithValues: persistence.state.windows.map { ($0.id, $0) })
        DiagnosticLog.write("memory", "\(closed.count) remembered window(s) vanished\(isFrozen ? " (frozen: shutdown)" : "")")
        for (windowID, recordID) in closed {
            binding[windowID] = nil
            guard !isFrozen, let record = savedWindows[recordID] else { continue }
            if !pendingWindows.contains(where: { $0.id == recordID }) {
                pendingWindows.append(record)
            }
            lostAt[recordID] = Date()
            for group in persistence.state.groups where group.members.contains(recordID) && !pendingGroups.contains(where: { $0.id == group.id }) {
                pendingGroups.append(group)
            }
        }
    }

    /// Drops lost records whose grace period ended.
    private func expireLostRecords(now: Date) {
        let expired = lostAt.filter { now.timeIntervalSince($0.value) > lostGrace }.map(\.key)
        guard !expired.isEmpty else { return }
        DiagnosticLog.write("memory", "\(expired.count) lost record(s) expired after grace period")
        for id in expired { lostAt[id] = nil }
        pendingWindows.removeAll { expired.contains($0.id) }
        for index in pendingGroups.indices {
            pendingGroups[index].members.removeAll { expired.contains($0) }
        }
        pendingGroups.removeAll { $0.members.count < 2 }
    }

    private func restorePending() {
        let now = Date()
        expireLostRecords(now: now)
        guard !pendingWindows.isEmpty else { return }
        if now.timeIntervalSince(launchedAt) > restoreWindow {
            // Only recently lost records may still be matched after the launch window.
            pendingWindows.removeAll { lostAt[$0.id] == nil }
            let keep = Set(pendingWindows.map(\.id))
            for index in pendingGroups.indices {
                pendingGroups[index].members.removeAll { !keep.contains($0) && binding.values.contains($0) == false }
            }
            pendingGroups.removeAll { $0.members.count < 2 }
            guard !pendingWindows.isEmpty else { return }
        }
        let bound = Set(binding.keys)
        let candidates: [FingerprintMatcher.Candidate] = store.snapshot.windows.compactMap { window in
            guard !bound.contains(window.id), store.customizations[window.id] == nil, store.group(containing: window.id) == nil,
                  let process = store.snapshot.processes[window.process] else { return nil }
            return FingerprintMatcher.Candidate(
                id: window.id,
                fingerprint: WindowFingerprint(
                    bundleIdentifier: process.bundleIdentifier,
                    applicationName: process.applicationName,
                    title: window.title,
                    pid: window.process.pid,
                    processStartUnixMs: window.process.startUnixMilliseconds
                ),
                order: window.firstSeenSequence
            )
        }
        guard !candidates.isEmpty else { return }
        let matches = FingerprintMatcher.match(pending: pendingWindows, candidates: candidates)
        guard !matches.isEmpty else { return }
        DiagnosticLog.write("memory", "re-attached \(matches.count) remembered window(s); \(pendingWindows.count - matches.count) still pending")

        for record in pendingWindows {
            guard let windowID = matches[record.id] else { continue }
            binding[windowID] = record.id
            lostAt[record.id] = nil
            if !record.customization.isEmpty {
                store.applyCustomization(record.customization, to: windowID)
            }
        }
        pendingWindows.removeAll { matches[$0.id] != nil }

        // Groups come back once at least two members are live; later members join.
        let recordToWindow = Dictionary(uniqueKeysWithValues: binding.map { ($0.value, $0.key) })
        for group in pendingGroups {
            let members = group.members.compactMap { recordToWindow[$0] }
            let groupID = GroupID(rawValue: group.id)
            if let existing = store.group(groupID) {
                for member in members where !existing.members.contains(member) {
                    store.stack(.window(member), onto: .group(groupID))
                }
            } else if members.count >= 2 {
                store.restoreGroup(id: groupID, name: group.name, badge: group.badge, colorToken: group.colorToken, members: members)
                DiagnosticLog.write("memory", "restored group with \(members.count) members")
            }
        }
        pendingGroups.removeAll { group in
            group.members.allSatisfy { recordToWindow[$0] != nil }
        }
    }

    /// Derives the persisted state from the live store plus still-pending records.
    private func save() {
        var windows: [PersistedWindow] = []
        var groups: [PersistedGroup] = []

        // A window whose group partner just vanished has no live group any more, but its record
        // must survive while the partner may still come back.
        let pendingMembers = Set(pendingGroups.flatMap(\.members))
        for window in store.snapshot.windows {
            let customization = store.customizations[window.id] ?? SessionCustomization()
            let inGroup = store.group(containing: window.id) != nil
            let awaitingPartner = binding[window.id].map { pendingMembers.contains($0) } ?? false
            guard !customization.isEmpty || inGroup || awaitingPartner, let process = store.snapshot.processes[window.process] else {
                binding[window.id] = nil
                continue
            }
            let recordID = binding[window.id] ?? UUID()
            binding[window.id] = recordID
            windows.append(PersistedWindow(
                id: recordID,
                fingerprint: WindowFingerprint(
                    bundleIdentifier: process.bundleIdentifier,
                    applicationName: process.applicationName,
                    title: window.title,
                    pid: window.process.pid,
                    processStartUnixMs: window.process.startUnixMilliseconds
                ),
                customization: customization
            ))
        }
        for group in store.arrangement.groupList {
            let members = group.members.compactMap { binding[$0] }
            guard members.count >= 2 else { continue }
            groups.append(PersistedGroup(id: group.id.rawValue, name: group.name, badge: group.badge, colorToken: group.colorToken, members: members))
        }

        // Keep unmatched records from the previous run (and their groups) until the restore
        // window closes.
        windows.append(contentsOf: pendingWindows)
        let knownIDs = Set(windows.map(\.id))
        for group in pendingGroups where groups.contains(where: { $0.id == group.id }) == false {
            let members = group.members.filter { knownIDs.contains($0) }
            if members.count >= 2 {
                groups.append(PersistedGroup(id: group.id, name: group.name, badge: group.badge, colorToken: group.colorToken, members: members))
            }
        }

        persistence.update { state in
            state.windows = windows
            state.groups = groups
        }
    }
}
