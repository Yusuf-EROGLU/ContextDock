import AppKit
import SwiftUI

/// The horizontal bar. Shows real windows and user-made groups; permission and empty states
/// are explicit. Cards can be dragged onto each other to form groups, or between cards to
/// reorder them.
struct DockBarView: View {
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 8
    static let minimumWidth: CGFloat = 360

    @Bindable var store: WindowStore
    @Bindable var barState: BarState
    var onActivate: (BarItemID) -> Void
    var onActivateMember: (WindowSessionID) -> Void
    var onMenu: (InteractionTarget) -> NSMenu
    var onRequestPermission: () -> Void
    var dragHandlers: DragHandlers

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            content
            if let toast = barState.toast {
                Text(toast.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(toast.isError ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(toast.isError ? Color.red.opacity(0.9) : Color.primary.opacity(0.15)))
                    .offset(y: -14)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel(toast.message)
            }
        }
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        )
        .overlay(alignment: .topLeading) { dragGhost }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: barState.toast)
    }

    @ViewBuilder
    private var content: some View {
        switch store.permission {
        case .denied, .revoked:
            permissionState
        case .unknown where !store.hasReceivedSnapshot:
            statusRow(symbol: "hourglass", text: "Looking for windows…")
        default:
            if store.items.isEmpty {
                statusRow(symbol: "macwindow.on.rectangle", text: "No windows found")
            } else {
                strip
            }
        }
    }

    private var strip: some View {
        HorizontalStrip(height: WindowCardView.height) {
            HStack(spacing: Self.spacing) {
                ForEach(store.items) { item in
                    insertionMarker(before: item.id)
                    itemView(item)
                        .opacity(barState.drag?.item == item.id ? 0.35 : 1)
                }
                insertionMarker(before: nil)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: BarItem) -> some View {
        switch item {
        case .window(let card):
            WindowCardView(
                card: card,
                icon: store.icon(for: card),
                isHovered: barState.hoveredItem == item.id,
                isKeyboardSelected: barState.keyboardSelectedItem == item.id,
                isDropTarget: barState.drag?.target == .stack(item.id),
                reduceMotion: reduceMotion
            )
            .overlay(interaction(.item(item.id), click: { onActivate(item.id) }))
        case .group(let group):
            GroupCardView(
                group: group,
                icon: { store.icon(for: $0) },
                isHovered: barState.hoveredItem == item.id,
                isKeyboardSelected: barState.keyboardSelectedItem == item.id,
                isDropTarget: barState.drag?.target == .stack(item.id),
                reduceMotion: reduceMotion,
                memberOverlay: { member in
                    AnyView(interaction(.member(member.id, in: group.id), click: { onActivateMember(member.id) }))
                }
            )
            .overlay(interaction(.item(item.id), click: { onActivate(item.id) }).allowsHitTesting(true))
        }
    }

    private func interaction(_ target: InteractionTarget, click: @escaping () -> Void) -> some View {
        CardInteractionView(
            target: target,
            onClick: click,
            onHover: { hovering in
                guard case .item(let id) = target else { return }
                if hovering {
                    barState.hoveredItem = id
                } else if barState.hoveredItem == id {
                    barState.hoveredItem = nil
                }
            },
            makeMenu: { onMenu(target) },
            drag: dragHandlers
        )
    }

    @ViewBuilder
    private func insertionMarker(before id: BarItemID?) -> some View {
        let active = barState.drag?.target == .insert(before: id)
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(width: 3, height: WindowCardView.height - 12)
            .opacity(active ? 1 : 0)
            .frame(width: active ? 3 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: active)
    }

    @ViewBuilder
    private var dragGhost: some View {
        if let drag = barState.drag {
            ghostLabel(for: drag)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.thickMaterial).shadow(radius: 6))
                .offset(x: drag.location.x + 12, y: drag.location.y - 40)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func ghostLabel(for drag: BarState.DragState) -> some View {
        HStack(spacing: 6) {
            switch drag.item {
            case .window(let id):
                if let card = store.card(for: id) {
                    if let icon = store.icon(for: card) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(card.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            case .group(let id):
                if let group = store.groupViewModel(id) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12))
                    Text(group.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
            Text(hint(for: drag.target)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func hint(for target: BarState.DropTarget?) -> String {
        switch target {
        case .stack: return "· stack into group"
        case .insert: return "· move here"
        case .detach: return "· remove from group"
        case nil: return ""
        }
    }

    private var permissionState: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.system(size: 22)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.permission == .revoked ? "Accessibility permission was revoked" : "Accessibility permission required")
                    .font(.system(size: 13, weight: .semibold))
                Text("ContextDock needs it to list windows and switch to them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Grant Access…") { onRequestPermission() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: Self.minimumWidth, minHeight: WindowCardView.height)
    }

    private func statusRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: Self.minimumWidth, minHeight: WindowCardView.height)
    }

    /// Width the bar wants for a given number of items (before capping to the screen).
    static func preferredWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return minimumWidth + 2 * padding }
        let cards = CGFloat(itemCount) * WindowCardView.width + CGFloat(itemCount - 1) * spacing
        return cards + 2 * padding
    }

    static var preferredHeight: CGFloat { WindowCardView.height + 2 * padding }
}
