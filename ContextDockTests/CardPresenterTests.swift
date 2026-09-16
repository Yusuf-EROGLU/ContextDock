import Foundation
import Testing
@testable import ContextDock

@Suite("CardPresenter")
struct CardPresenterTests {
    private let process = ProcessSnapshot.test()

    private func context(project: String? = nil, branch: String? = nil, structured: String? = nil, source: ContextSource = .windowTitle, stale: Bool = false) -> WindowContext {
        var context = WindowContext.none()
        context.projectDisplayName = project
        context.branchName = branch
        context.structuredLabel = structured
        context.contextSource = source
        context.isStale = stale
        return context
    }

    @Test("custom name beats structured label, which beats project name, which beats title")
    func labelPriority() {
        let window = WindowSnapshot.test(title: "Raw title")
        let ctx = context(project: "music-game", branch: "main", structured: "Backend", source: .structuredTitle)

        let named = CardPresenter.resolve(window: window, process: process, customization: SessionCustomization(name: "My name"), context: ctx)
        #expect(named.title == "My name")
        #expect(named.hasCustomName)

        let structured = CardPresenter.resolve(window: window, process: process, customization: nil, context: ctx)
        #expect(structured.title == "Backend")
        #expect(structured.subtitle == "music-game · main")

        let project = CardPresenter.resolve(window: window, process: process, customization: nil, context: context(project: "music-game", source: .unityBridge))
        #expect(project.title == "music-game")
        #expect(project.subtitle == "Raw title")

        let plain = CardPresenter.resolve(window: window, process: process, customization: nil, context: context())
        #expect(plain.title == "Raw title")
        #expect(plain.subtitle == "Ghostty")
    }

    @Test("untitled windows are labelled explicitly")
    func untitled() {
        let card = CardPresenter.resolve(window: .test(title: nil), process: process, customization: nil, context: .none())
        #expect(card.title == CardPresenter.untitledWindowLabel)
        let blank = CardPresenter.resolve(window: .test(title: "   "), process: process, customization: nil, context: .none())
        #expect(blank.title == CardPresenter.untitledWindowLabel)
    }

    @Test("stale bridge context is marked in the subtitle")
    func staleSubtitle() {
        let card = CardPresenter.resolve(window: .test(title: "T"), process: process, customization: nil, context: context(project: "game", source: .unityBridge, stale: true))
        #expect(card.title == "game")
        #expect(card.subtitle == "T")
        let named = CardPresenter.resolve(window: .test(title: "T"), process: process, customization: SessionCustomization(name: "X"), context: context(project: "game", source: .unityBridge, stale: true))
        #expect(named.subtitle == "game (stale)")
    }

    @Test("badge and color come from the session customization")
    func badgeAndColor() {
        let card = CardPresenter.resolve(window: .test(), process: process, customization: SessionCustomization(badge: .emoji("🧪"), colorToken: .purple), context: .none())
        #expect(card.badge == .emoji("🧪"))
        #expect(card.colorToken == .purple)
        let plain = CardPresenter.resolve(window: .test(), process: process, customization: nil, context: .none())
        #expect(plain.colorToken == ColorToken.none)
    }

    @Test("group title lists member apps unless named")
    func groupTitle() {
        let a = CardPresenter.resolve(window: .test(title: "A"), process: .test(kind: .unityEditor, name: "Unity", active: true), customization: nil, context: .none())
        let b = CardPresenter.resolve(window: .test(title: "B"), process: .test(key: .test(pid: 2), kind: .ghostty, name: "Ghostty"), customization: nil, context: .none())
        let c = CardPresenter.resolve(window: .test(title: "C"), process: .test(key: .test(pid: 3), kind: .ghostty, name: "Ghostty"), customization: nil, context: .none())
        let group = WindowGroup(members: [a.id, b.id, c.id])
        let unnamed = CardPresenter.resolveGroup(group, members: [a, b, c])
        #expect(unnamed.title == "Unity + Ghostty")
        #expect(unnamed.subtitle == "3 windows")
        #expect(!unnamed.hasCustomName)

        var named = group
        named.name = "Audio task"
        let resolved = CardPresenter.resolveGroup(named, members: [a, b, c])
        #expect(resolved.title == "Audio task")
        #expect(resolved.subtitle == "3 windows · Unity, Ghostty")
        #expect(resolved.isActive == false, "process active but window neither focused nor main")
    }

    @Test("accessibility label mentions app, title and states")
    func accessibility() {
        let card = CardPresenter.resolve(window: .test(title: "T", minimized: true, stale: true), process: .test(hidden: true), customization: nil, context: .none())
        #expect(card.accessibilityLabel.contains("Ghostty"))
        #expect(card.accessibilityLabel.contains("minimized"))
        #expect(card.accessibilityLabel.contains("hidden"))
        #expect(card.accessibilityLabel.contains("outdated"))
    }
}
