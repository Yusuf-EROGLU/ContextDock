import AppKit
import SwiftUI

struct PermissionView: View {
    let permission: PermissionState
    var onRequest: () -> Void
    var onOpenSettings: () -> Void
    var onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility access required")
                        .font(.title3.weight(.semibold))
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("ContextDock needs Accessibility access to read other applications' window titles and to switch to the window you pick. It does not read window contents, terminal output, or keystrokes, and it never sends data anywhere.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Click “Request Access”, then enable ContextDock under System Settings › Privacy & Security › Accessibility. The system prompt appears asynchronously; ContextDock re-checks when you return.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { onOpenSettings() }
                Spacer()
                Button("Check Again") { onRecheck() }
                Button("Request Access") { onRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(permission.isGranted)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var statusLine: String {
        switch permission {
        case .granted: return "Access granted. You can close this window."
        case .revoked: return "Access was removed while ContextDock was running."
        case .denied: return "Not granted yet."
        case .unknown: return "Checking…"
        }
    }
}

@MainActor
final class PermissionWindowController {
    private var window: NSWindow?
    private let store: WindowStore
    var onRecheck: (() -> Void)?

    init(store: WindowStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let view = PermissionView(
                permission: store.permission,
                onRequest: { AXPermission.requestTrust() },
                onOpenSettings: { NSWorkspace.shared.open(AXPermission.systemSettingsURL) },
                onRecheck: { [weak self] in self?.onRecheck?() }
            )
            let hosting = NSHostingView(rootView: PermissionRootView(store: store, base: view))
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hosting
            window.styleMask = [.titled, .closable]
            window.title = "ContextDock"
            window.isReleasedWhenClosed = false
            window.setContentSize(hosting.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}

/// Re-renders the permission view when the store's permission changes.
private struct PermissionRootView: View {
    @Bindable var store: WindowStore
    let base: PermissionView

    var body: some View {
        PermissionView(
            permission: store.permission,
            onRequest: base.onRequest,
            onOpenSettings: base.onOpenSettings,
            onRecheck: base.onRecheck
        )
    }
}
