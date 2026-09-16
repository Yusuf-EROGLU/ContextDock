import Foundation
import Testing
@testable import ContextDock

@Suite("CardPresenter")
struct CardPresenterTests {
    private let process = ProcessSnapshot.test()

    private func context(path: String? = nil, confidence: ContextConfidence = .unknown, branch: String? = nil, status: GitStatus? = nil, detached: Bool? = nil, unborn: Bool? = nil, stale: Bool = false, structured: String? = nil) -> WindowContext {
        var context = WindowContext.none()
        context.projectPath = path
        context.projectDisplayName = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        context.worktreeRoot = path
        context.confidence = confidence
        context.contextSource = path == nil ? (structured == nil ? .windowTitle : .structuredTitle) : .manual
        context.branchName = branch
        context.gitStatus = status
        context.isDetached = detached
        context.isUnborn = unborn
        context.gitIsStale = stale
        context.structuredLabel = structured
        if detached == true { context.shortCommit = "a1b2c3d" }
        return context
    }

    @Test("custom name beats rule label, rule beats project name, project name beats title")
    func labelPriority() {
        let window = WindowSnapshot.test(title: "Raw title")
        let rule = ProjectRule(id: UUID(), applicationKind: .ghostty, projectPath: "/p/game", customLabel: "Rule label", badge: nil, colorToken: nil, createdAt: Date(), updatedAt: Date())
        let verified = context(path: "/p/game", confidence: .userConfirmed, branch: "main", status: .ok)

        let withName = CardPresenter.resolve(window: window, process: process, customization: SessionCustomization(name: "My name"), rule: rule, context: verified)
        #expect(withName.title == "My name")
        #expect(withName.hasCustomName)

        let withRule = CardPresenter.resolve(window: window, process: process, customization: nil, rule: rule, context: verified)
        #expect(withRule.title == "Rule label")
        #expect(withRule.subtitle == "game · main")

        let withProject = CardPresenter.resolve(window: window, process: process, customization: nil, rule: nil, context: verified)
        #expect(withProject.title == "game")

        let plain = CardPresenter.resolve(window: window, process: process, customization: nil, rule: nil, context: context())
        #expect(plain.title == "Raw title")
        #expect(plain.subtitle == "Ghostty")
    }

    @Test("a rule is ignored when the project path is not trusted")
    func ruleRequiresTrustedPath() {
        let window = WindowSnapshot.test(title: "Raw")
        let rule = ProjectRule(id: UUID(), applicationKind: .ghostty, projectPath: "/p/game", customLabel: "Rule", badge: .emoji("🧪"), colorToken: .purple, createdAt: Date(), updatedAt: Date())
        let inferred = context(path: "/p/game", confidence: .inferred)
        let card = CardPresenter.resolve(window: window, process: process, customization: nil, rule: rule, context: inferred)
        #expect(card.title == "game")
        #expect(card.badge == nil)
        #expect(card.colorToken == ColorToken.none)
    }

    @Test("untitled windows are labelled explicitly")
    func untitled() {
        let card = CardPresenter.resolve(window: .test(title: nil), process: process, customization: nil, rule: nil, context: .none())
        #expect(card.title == CardPresenter.untitledWindowLabel)
        let blank = CardPresenter.resolve(window: .test(title: "   "), process: process, customization: nil, rule: nil, context: .none())
        #expect(blank.title == CardPresenter.untitledWindowLabel)
    }

    @Test("git line variants")
    func gitLines() {
        let base = "/Users/me/Worktrees/music-game-audio"
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, branch: "feature/audio", status: .ok)) == "music-game-audio · feature/audio")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, status: .ok, detached: true)) == "music-game-audio · detached · a1b2c3d")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, branch: "main", status: .ok, unborn: true)) == "music-game-audio · main · no commits")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, branch: "main", status: .ok, stale: true)) == "music-game-audio · main (stale)")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, status: .notARepository)) == "music-game-audio · not a Git repository")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, status: .gitMissing)) == "music-game-audio · Git not found")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, status: .noAccess)) == "music-game-audio · no access")
        #expect(CardPresenter.gitLine(context: context(path: base, confidence: .verified, status: .unknown(reason: "timeout"))) == "music-game-audio · unknown")
    }

    @Test("structured title provides label and branch for display only")
    func structuredTitle() {
        var ctx = context(structured: "Backend")
        ctx.branchName = "feature/auth"
        let card = CardPresenter.resolve(window: .test(title: "CDOCK:v1|label=Backend"), process: process, customization: nil, rule: nil, context: ctx)
        #expect(card.title == "Backend")
        #expect(card.subtitle == "CDOCK:v1|label=Backend" || card.subtitle == "feature/auth")
        #expect(card.projectPath == nil)
    }

    @Test("accessibility label mentions app, title and states")
    func accessibility() {
        let card = CardPresenter.resolve(window: .test(title: "T", minimized: true, stale: true), process: .test(hidden: true), customization: nil, rule: nil, context: .none())
        #expect(card.accessibilityLabel.contains("Ghostty"))
        #expect(card.accessibilityLabel.contains("minimized"))
        #expect(card.accessibilityLabel.contains("hidden"))
        #expect(card.accessibilityLabel.contains("outdated"))
    }
}
