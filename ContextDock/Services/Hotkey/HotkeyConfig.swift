import Foundation

/// A global keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask).
struct HotkeyConfig: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    // Carbon modifier bits (Events.h). Spelled out so this file has no Carbon dependency.
    static let commandKeyBit: UInt32 = 1 << 8
    static let shiftKeyBit: UInt32 = 1 << 9
    static let optionKeyBit: UInt32 = 1 << 11
    static let controlKeyBit: UInt32 = 1 << 12

    static let spaceKeyCode: UInt32 = 49

    /// Control + Option + Space.
    static let `default` = HotkeyConfig(keyCode: spaceKeyCode, carbonModifiers: controlKeyBit | optionKeyBit)

    var hasModifier: Bool {
        carbonModifiers & (Self.commandKeyBit | Self.shiftKeyBit | Self.optionKeyBit | Self.controlKeyBit) != 0
    }

    var displayString: String {
        var parts = ""
        if carbonModifiers & Self.controlKeyBit != 0 { parts += "⌃" }
        if carbonModifiers & Self.optionKeyBit != 0 { parts += "⌥" }
        if carbonModifiers & Self.shiftKeyBit != 0 { parts += "⇧" }
        if carbonModifiers & Self.commandKeyBit != 0 { parts += "⌘" }
        return parts + KeyCodeNames.name(for: keyCode)
    }
}

/// Human-readable names for common virtual key codes (ANSI layout).
enum KeyCodeNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
