import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var store: WindowStore
    @Bindable var persistence: PersistenceService
    var onResetAll: () -> Void
    var hotkeySection: AnyView?

    var body: some View {
        Form {
            Section("Bar") {
                Toggle("Show bar", isOn: $preferences.barVisible)
                Picker("Position", selection: $preferences.barEdge) {
                    ForEach(BarEdge.allCases, id: \.self) { edge in
                        Text(edge.displayName).tag(edge)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Edge margin")
                    Slider(value: $preferences.bottomMargin, in: 0...120, step: 4)
                    Text("\(Int(preferences.bottomMargin)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Picker("Screen", selection: $preferences.screenSelection) {
                    Text("Primary display").tag(ScreenSelection.primary)
                    Text("Display with active window").tag(ScreenSelection.mainWindowScreen)
                    Text("Display under mouse").tag(ScreenSelection.mouseScreen)
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = ScreenPlacement.displayID(of: screen) {
                            Text(screen.localizedName).tag(ScreenSelection.display(id: id))
                        }
                    }
                }
            }
            Section("Cards") {
                HStack {
                    Text("Card width")
                    Slider(value: $preferences.cardWidth, in: CardMetrics.widthRange, step: 10)
                    Text("\(Int(preferences.cardWidth)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Card height")
                    Slider(value: $preferences.cardHeight, in: CardMetrics.heightRange, step: 4)
                    Text("\(Int(preferences.cardHeight)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text(preferences.cardMetrics.showsSubtitle ? "Two lines per card." : "Compact: one line per card.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Size") { preferences.resetCardMetrics() }
                }
            }
            if let hotkeySection {
                Section("Keyboard") { hotkeySection }
            }
            Section("Windows") {
                Toggle("Show auxiliary windows (dialogs, floating tool windows)", isOn: $preferences.showAuxiliaryWindows)
                Text("Drag a card onto another to group them; click a group to bring all of its windows forward. Names and groups last for this ContextDock session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Toggle("Verbose debug logging (includes titles in the unified log)", isOn: $preferences.debugLogging)
                Button("Reset all names, badges and groups…", role: .destructive) { onResetAll() }
                persistenceStatus
                Text("Data: \(PersistenceService.applicationSupportDirectory.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    @ViewBuilder
    private var persistenceStatus: some View {
        switch persistence.status {
        case .ok:
            EmptyView()
        case .corruptFilePreserved(let url):
            Label("The settings file was unreadable and has been preserved\(url.map { " at \($0.lastPathComponent)" } ?? ""). Defaults are in use.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .readOnlyNewerSchema(let found):
            Label("The settings file was written by a newer ContextDock (schema \(found)). Saving is disabled to protect it.", systemImage: "lock")
                .foregroundStyle(.orange)
        case .saveFailed(let message):
            Label("Saving failed: \(message)", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: makeView())
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hosting
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "ContextDock Settings"
            window.isReleasedWhenClosed = false
            window.setContentSize(hosting.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
