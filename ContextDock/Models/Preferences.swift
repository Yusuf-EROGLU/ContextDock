import Foundation
import Observation

/// Which screen hosts the bar.
enum ScreenSelection: Sendable, Hashable, Codable {
    case primary
    case mainWindowScreen
    case mouseScreen
    case display(id: UInt32)
}

/// Simple user preferences backed by `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    enum Keys {
        static let barVisible = "barVisible"
        static let bottomMargin = "bottomMargin"
        static let screenSelection = "screenSelection"
        static let showAuxiliaryWindows = "showAuxiliaryWindows"
        static let debugLogging = "debugLogging"
        static let barLevelAboveFullScreen = "barLevelAboveFullScreen"
    }

    private let defaults: UserDefaults

    var barVisible: Bool { didSet { defaults.set(barVisible, forKey: Keys.barVisible) } }
    var bottomMargin: Double { didSet { defaults.set(bottomMargin, forKey: Keys.bottomMargin) } }
    var screenSelection: ScreenSelection {
        didSet {
            if let data = try? JSONEncoder().encode(screenSelection) {
                defaults.set(data, forKey: Keys.screenSelection)
            }
        }
    }
    var showAuxiliaryWindows: Bool { didSet { defaults.set(showAuxiliaryWindows, forKey: Keys.showAuxiliaryWindows) } }
    var debugLogging: Bool { didSet { defaults.set(debugLogging, forKey: Keys.debugLogging) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.barVisible: true,
            Keys.bottomMargin: 12.0,
            Keys.showAuxiliaryWindows: false,
            Keys.debugLogging: false,
        ])
        barVisible = defaults.bool(forKey: Keys.barVisible)
        bottomMargin = defaults.double(forKey: Keys.bottomMargin)
        showAuxiliaryWindows = defaults.bool(forKey: Keys.showAuxiliaryWindows)
        debugLogging = defaults.bool(forKey: Keys.debugLogging)
        if let data = defaults.data(forKey: Keys.screenSelection),
           let selection = try? JSONDecoder().decode(ScreenSelection.self, from: data) {
            screenSelection = selection
        } else {
            screenSelection = .primary
        }
    }
}
