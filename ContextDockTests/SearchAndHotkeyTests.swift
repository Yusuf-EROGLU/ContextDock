import Foundation
import Testing
@testable import ContextDock

@Suite("SearchMatcher")
struct SearchMatcherTests {
    private func candidate(_ order: Int, label: String, app: String = "Ghostty", title: String? = nil, project: String? = nil, branch: String? = nil) -> SearchCandidate {
        SearchCandidate(id: WindowSessionID(), order: order, label: label, applicationName: app, title: title, projectName: project, branch: branch)
    }

    @Test func emptyQueryKeepsBarOrder() {
        let c = [candidate(2, label: "B"), candidate(0, label: "A"), candidate(1, label: "C")]
        #expect(SearchMatcher.rank("", in: c).map(\.label) == ["A", "C", "B"])
    }

    @Test("label matches rank above title matches; diacritics and case are ignored")
    func weighting() {
        let c = [
            candidate(0, label: "Backend", title: "ses deneyi"),
            candidate(1, label: "Ses Deneyi", app: "Unity", project: "music-game-audio", branch: "feature/audio"),
        ]
        #expect(SearchMatcher.rank("ses", in: c).first?.label == "Ses Deneyi")
        #expect(SearchMatcher.rank("SES", in: c).first?.label == "Ses Deneyi")
        #expect(SearchMatcher.rank("audio", in: c).map(\.label) == ["Ses Deneyi"])
        #expect(SearchMatcher.rank("müzik", in: [candidate(0, label: "Muzik Oyunu")]).count == 1)
    }

    @Test func subsequenceFallback() {
        let c = [candidate(0, label: "music-game-audio")]
        #expect(SearchMatcher.rank("mga", in: c).count == 1)
        #expect(SearchMatcher.rank("xyz", in: c).isEmpty)
    }

    @Test func multipleTermsMustAllMatch() {
        let c = [candidate(0, label: "Backend", branch: "dev"), candidate(1, label: "Backend", branch: "main")]
        #expect(SearchMatcher.rank("backend main", in: c).count == 1)
    }
}

@Suite("HotkeyConfig")
struct HotkeyConfigTests {
    @Test func defaultIsControlOptionSpace() {
        #expect(HotkeyConfig.default.displayString == "⌃⌥Space")
        #expect(HotkeyConfig.default.hasModifier)
    }

    @Test func codableRoundTrip() throws {
        let config = HotkeyConfig(keyCode: 12, carbonModifiers: HotkeyConfig.commandKeyBit | HotkeyConfig.shiftKeyBit)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(HotkeyConfig.self, from: data) == config)
        #expect(config.displayString == "⇧⌘Q")
    }

    @Test func noModifierIsRejected() {
        #expect(!HotkeyConfig(keyCode: 0, carbonModifiers: 0).hasModifier)
    }
}
