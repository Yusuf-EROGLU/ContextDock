import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var store: WindowStore
    @Bindable var persistence: PersistenceService
    var onResetAll: () -> Void
    var onDeleteRule: (UUID) -> Void
    var hotkeySection: AnyView?

    var body: some View {
        Form {
            Section("Bar") {
                Toggle("Show bar", isOn: $preferences.barVisible)
                HStack {
                    Text("Bottom margin")
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
            if let hotkeySection {
                Section("Keyboard") { hotkeySection }
            }
            Section("Windows") {
                Toggle("Show auxiliary windows (dialogs, floating tool windows)", isOn: $preferences.showAuxiliaryWindows)
                Toggle("Read Unity project path from process arguments", isOn: $preferences.readProcessArguments)
            }
            Section("Project rules") {
                if persistence.state.projectRules.isEmpty {
                    Text("No saved project rules. Use “Remember for this project” after attaching a project folder.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(persistence.state.projectRules) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rule.customLabel ?? URL(fileURLWithPath: rule.projectPath).lastPathComponent)
                                Text("\(rule.applicationKind.displayName) · \(rule.projectPath)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if let badge = rule.badge {
                                if badge.kind == .emoji { Text(badge.value) } else { Image(systemName: badge.value) }
                            }
                            Button(role: .destructive) { onDeleteRule(rule.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete rule")
                        }
                    }
                }
                persistenceStatus
            }
            Section("Advanced") {
                Toggle("Verbose debug logging (includes titles and paths in the unified log)", isOn: $preferences.debugLogging)
                Button("Reset all customizations…", role: .destructive) { onResetAll() }
                Text("Data: \(PersistenceService.applicationSupportDirectory.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
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
