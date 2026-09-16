import AppKit
import Carbon.HIToolbox

enum HotkeyError: Error, Equatable, Sendable {
    /// Another application already registered this combination.
    case conflict
    case failed(OSStatus)
    case noModifier

    var message: String {
        switch self {
        case .conflict: return "This shortcut is already in use by another app."
        case .failed(let status): return "Registering the shortcut failed (error \(status))."
        case .noModifier: return "Choose at least one modifier key."
        }
    }
}

/// Registers one global hotkey with Carbon's `RegisterEventHotKey` (public API; only the
/// chosen combination is delivered, no key logging). Runs on the main actor because Carbon
/// dispatches the event to the main run loop.
@MainActor
final class CarbonHotkeyRegistrar {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private(set) var current: HotkeyConfig?
    var onPressed: (() -> Void)?

    private static let signature: OSType = 0x4344_434B // "CDCK"
    private static let hotKeyID: UInt32 = 1

    init() {}

    func register(_ config: HotkeyConfig) -> Result<Void, HotkeyError> {
        guard config.hasModifier else { return .failure(.noModifier) }
        installHandlerIfNeeded()
        unregister()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(config.keyCode, config.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) { return .failure(.conflict) }
            return .failure(.failed(status))
        }
        hotKeyRef = ref
        current = config
        return .success(())
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        current = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, userData, &handlerRef)
    }

    fileprivate func handle(signature: OSType, id: UInt32) {
        guard signature == Self.signature, id == Self.hotKeyID else { return }
        onPressed?()
    }

    /// Removes the Carbon handler and hot key. The registrar normally lives for the whole run.
    func invalidate() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

/// Carbon delivers hot key events on the main thread.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let signature = hotKeyID.signature
    let id = hotKeyID.id
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        registrar.handle(signature: signature, id: id)
    }
    return noErr
}

extension HotkeyConfig {
    /// Builds a config from an AppKit key event.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= HotkeyConfig.commandKeyBit }
        if flags.contains(.shift) { carbon |= HotkeyConfig.shiftKeyBit }
        if flags.contains(.option) { carbon |= HotkeyConfig.optionKeyBit }
        if flags.contains(.control) { carbon |= HotkeyConfig.controlKeyBit }
        guard carbon != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }
}
