import Foundation

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

/// Inputs for one window, gathered from every available automatic source.
struct ContextInputs: Sendable {
    var bridge: UnityBridgeReport?
    var bridgeIsStale = false
    var structuredTitle: StructuredTitle?
    var rawTitle: String?
}

/// Pure merge of context sources: Unity bridge > structured title > plain window title.
enum ContextResolver {
    static func resolve(_ inputs: ContextInputs, now: Date = Date()) -> WindowContext {
        var context = WindowContext.none(at: now)

        if let bridge = inputs.bridge {
            context.projectPath = PathNormalizer.normalize(bridge.projectPath)
            context.projectDisplayName = bridge.projectName
            context.contextSource = .unityBridge
            context.confidence = .verified
            context.isStale = inputs.bridgeIsStale
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

        context.lastUpdatedAt = now
        return context
    }
}
