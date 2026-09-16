import ApplicationServices
import Foundation

/// Accessibility trust state. The prompt is only ever shown from an explicit user action.
enum AXPermission {
    /// `kAXTrustedCheckOptionPrompt` is a global C variable that Swift 6 rejects as shared
    /// mutable state; the string constant is documented and stable.
    private static var promptOptionKey: CFString { "AXTrustedCheckOptionPrompt" as CFString }

    static func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Asks the system to show its Accessibility prompt (asynchronous; returning `true` only
    /// means trust was already granted).
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [promptOptionKey: kCFBooleanTrue] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
