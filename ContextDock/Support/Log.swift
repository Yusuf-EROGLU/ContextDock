import Foundation
import os

/// Central logging. Window titles and file system paths are potentially sensitive and are
/// logged with `.private` privacy unless the user enabled verbose debug logging.
enum Log {
    private static let subsystem = "com.yusuferoglu.ContextDock"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let git = Logger(subsystem: subsystem, category: "git")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let integrations = Logger(subsystem: subsystem, category: "integrations")

    /// Verbose logging is opt-in (Settings > Advanced). Read through UserDefaults so it can be
    /// consulted from any isolation domain.
    static var verbose: Bool {
        UserDefaults.standard.bool(forKey: "debugLogging")
    }
}
