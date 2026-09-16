import Foundation

/// A project path hint read from a process's arguments (`-projectPath`).
struct ProcessArgumentsHint: Sendable, Hashable {
    var projectPath: String
    var validation: ProjectFolderValidation
}

/// Metadata reported by the optional Unity Editor bridge, already matched to a process.
struct UnityBridgeReport: Sendable, Hashable, Codable {
    var pid: pid_t
    var processStartedAtUnixMs: Int64
    var editorSessionId: String
    var projectPath: String
    var projectName: String
    var unityVersion: String?
    var updatedAtUnixMs: Int64

    var updatedAt: Date { Date(timeIntervalSince1970: TimeInterval(updatedAtUnixMs) / 1000) }
}

/// Display-only data parsed from a structured terminal title (`CDOCK:v1|…`).
struct StructuredTitle: Sendable, Hashable {
    var label: String?
    var project: String?
    var branch: String?
}

/// Inputs for one window, gathered from every available source.
struct ContextInputs: Sendable {
    var manual: ProjectBinding?
    var bridge: UnityBridgeReport?
    var bridgeIsStale = false
    var processArguments: ProcessArgumentsHint?
    var structuredTitle: StructuredTitle?
    var rawTitle: String?
    var git: GitInfo?
}

/// Pure merge of context sources with the spec priority:
/// manual > bridge > process arguments > structured title > window title.
enum ContextResolver {
    static func resolve(_ inputs: ContextInputs, now: Date = Date()) -> WindowContext {
        var context = WindowContext.none(at: now)

        if let manual = inputs.manual {
            context.projectPath = manual.normalizedPath
            context.projectDisplayName = URL(fileURLWithPath: manual.normalizedPath).lastPathComponent
            context.contextSource = .manual
            context.confidence = .userConfirmed
            if let bridge = inputs.bridge, PathNormalizer.normalize(bridge.projectPath) != manual.normalizedPath {
                context.conflictNote = "Unity bridge reports a different project: \(bridge.projectName)"
            } else if let args = inputs.processArguments, PathNormalizer.normalize(args.projectPath) != manual.normalizedPath {
                context.conflictNote = "Process arguments point to a different project: \(URL(fileURLWithPath: args.projectPath).lastPathComponent)"
            }
        } else if let bridge = inputs.bridge {
            context.projectPath = PathNormalizer.normalize(bridge.projectPath)
            context.projectDisplayName = bridge.projectName
            context.contextSource = .unityBridge
            context.confidence = .verified
            context.isStale = inputs.bridgeIsStale
        } else if let args = inputs.processArguments, args.validation == .unityProject {
            context.projectPath = PathNormalizer.normalize(args.projectPath)
            context.projectDisplayName = URL(fileURLWithPath: args.projectPath).lastPathComponent
            context.contextSource = .processArguments
            context.confidence = .verified
        } else if let structured = inputs.structuredTitle {
            context.structuredLabel = structured.label
            context.projectDisplayName = structured.project
            context.branchName = structured.branch
            context.contextSource = .structuredTitle
            context.confidence = .inferred
        } else if inputs.rawTitle != nil {
            context.contextSource = .windowTitle
            context.confidence = .unknown
        }

        if context.hasTrustedProjectPath, let git = inputs.git {
            context.worktreeRoot = git.worktreeRoot
            context.repositoryRoot = git.repositoryRoot
            context.branchName = git.branchName
            context.shortCommit = git.shortCommit
            context.isDetached = git.isDetached
            context.isUnborn = git.isUnborn
            context.gitStatus = git.status
            context.gitIsStale = git.isStale
        } else if context.hasTrustedProjectPath {
            context.worktreeRoot = context.projectPath
        }

        context.lastUpdatedAt = now
        return context
    }
}
