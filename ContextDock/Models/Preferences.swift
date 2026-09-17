import Foundation
import Observation

/// Which screen hosts the bar.
enum ScreenSelection: Sendable, Hashable, Codable {
    case primary
    case mainWindowScreen
    case mouseScreen
    case display(id: UInt32)
}

/// Screen edge the bar is attached to. Left/right lay the cards out vertically.
enum BarEdge: String, Sendable, Hashable, Codable, CaseIterable {
    case bottom
    case top
    case left
    case right

    var isVertical: Bool { self == .left || self == .right }

    var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Card dimensions chosen by the user. Everything in the bar derives its layout from these.
struct CardMetrics: Sendable, Hashable {
    static let defaultWidth: Double = 190
    static let defaultHeight: Double = 56
    static let widthRange: ClosedRange<Double> = 140...280
    static let heightRange: ClosedRange<Double> = 40...84

    var width: CGFloat
    var height: CGFloat

    /// Below this height the second line is dropped.
    var showsSubtitle: Bool { height >= 50 }
    var iconSize: CGFloat { min(36, max(22, height - 20)) }
    var titleFontSize: CGFloat { height >= 64 ? 14 : 13 }
}

/// Simple user preferences backed by `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    enum Keys {
        static let barVisible = "barVisible"
        static let bottomMargin = "bottomMargin"
        static let barEdge = "barEdge"
        static let cardWidth = "cardWidth"
        static let cardHeight = "cardHeight"
        static let screenSelection = "screenSelection"
        static let showAuxiliaryWindows = "showAuxiliaryWindows"
        static let debugLogging = "debugLogging"
        static let barLevelAboveFullScreen = "barLevelAboveFullScreen"
    }

    private let defaults: UserDefaults

    var barVisible: Bool { didSet { defaults.set(barVisible, forKey: Keys.barVisible) } }
    /// Distance between the bar and its screen edge.
    var bottomMargin: Double { didSet { defaults.set(bottomMargin, forKey: Keys.bottomMargin) } }
    var barEdge: BarEdge { didSet { defaults.set(barEdge.rawValue, forKey: Keys.barEdge) } }
    var cardWidth: Double { didSet { defaults.set(cardWidth, forKey: Keys.cardWidth) } }
    var cardHeight: Double { didSet { defaults.set(cardHeight, forKey: Keys.cardHeight) } }

    var cardMetrics: CardMetrics {
        CardMetrics(width: CGFloat(cardWidth), height: CGFloat(cardHeight))
    }

    func resetCardMetrics() {
        cardWidth = CardMetrics.defaultWidth
        cardHeight = CardMetrics.defaultHeight
    }
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
            Keys.barEdge: BarEdge.bottom.rawValue,
            Keys.cardWidth: CardMetrics.defaultWidth,
            Keys.cardHeight: CardMetrics.defaultHeight,
            Keys.showAuxiliaryWindows: false,
            Keys.debugLogging: false,
        ])
        barVisible = defaults.bool(forKey: Keys.barVisible)
        bottomMargin = defaults.double(forKey: Keys.bottomMargin)
        barEdge = BarEdge(rawValue: defaults.string(forKey: Keys.barEdge) ?? "") ?? .bottom
        cardWidth = min(max(defaults.double(forKey: Keys.cardWidth), CardMetrics.widthRange.lowerBound), CardMetrics.widthRange.upperBound)
        cardHeight = min(max(defaults.double(forKey: Keys.cardHeight), CardMetrics.heightRange.lowerBound), CardMetrics.heightRange.upperBound)
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
