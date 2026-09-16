import AppKit
import SwiftUI

/// Settings row that shows the global shortcut, lets the user record a new one and surfaces
/// registration errors with the menu fallback.
struct HotkeySettingsView: View {
    @Bindable var model: HotkeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search shortcut")
                Spacer()
                HotkeyRecorder(isRecording: $model.isRecording) { config in
                    model.apply(config)
                }
                .frame(width: 160, height: 24)
                Button(model.isRecording ? "Cancel" : "Change") { model.isRecording.toggle() }
                Button("Reset") { model.apply(.default) }
            }
            HStack(spacing: 6) {
                Text("Current: \(model.registered?.displayString ?? "none")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("macOS only reports a conflict for shortcuts this app already registered; another app can silently own the same keys. If the shortcut does nothing, pick a different combination. The Search Windows… menu item always works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
@Observable
final class HotkeyModel {
    var isRecording = false
    private(set) var registered: HotkeyConfig?
    private(set) var error: HotkeyError?
    private let registrar: CarbonHotkeyRegistrar
    private let persistence: PersistenceService

    init(registrar: CarbonHotkeyRegistrar, persistence: PersistenceService) {
        self.registrar = registrar
        self.persistence = persistence
    }

    func registerSaved() {
        apply(persistence.state.hotkey ?? .default, persist: false)
    }

    func apply(_ config: HotkeyConfig, persist: Bool = true) {
        isRecording = false
        switch registrar.register(config) {
        case .success:
            registered = config
            error = nil
            if persist { persistence.update { $0.hotkey = config } }
        case .failure(let failure):
            registered = registrar.current
            error = failure
            Log.app.error("Hotkey registration failed: \(failure.message, privacy: .public)")
        }
    }
}

/// Captures one key combination when recording.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onRecord: (HotkeyConfig) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.isRecording = isRecording
        if isRecording { nsView.window?.makeFirstResponder(nsView) }
    }

    final class RecorderView: NSView {
        var onRecord: ((HotkeyConfig) -> Void)?
        var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = isRecording ? "Press shortcut…" : "Click Change to record"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { // Escape cancels recording
                isRecording = false
                return
            }
            guard let config = HotkeyConfig(event: event) else {
                NSSound.beep()
                return
            }
            onRecord?(config)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, let config = HotkeyConfig(event: event) else { return false }
            onRecord?(config)
            return true
        }
    }
}
