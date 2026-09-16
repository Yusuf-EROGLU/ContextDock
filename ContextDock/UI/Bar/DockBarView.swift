import AppKit
import SwiftUI

/// The horizontal bar. Shows real windows only; permission and empty states are explicit.
struct DockBarView: View {
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 8
    static let minimumWidth: CGFloat = 360

    @Bindable var store: WindowStore
    @Bindable var barState: BarState
    var onActivate: (WindowSessionID) -> Void
    var onMenu: (WindowSessionID) -> NSMenu
    var onRequestPermission: () -> Void

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
            if store.cards.isEmpty {
                statusRow(symbol: "macwindow.on.rectangle", text: "No windows found")
            } else {
                cards
            }
        }
    }

    private var cards: some View {
        HorizontalStrip(height: WindowCardView.height) {
            HStack(spacing: Self.spacing) {
                ForEach(store.cards) { card in
                    WindowCardView(
                        card: card,
                        icon: store.icon(for: card),
                        isHovered: barState.hoveredCard == card.id,
                        isKeyboardSelected: barState.keyboardSelectedCard == card.id,
                        reduceMotion: reduceMotion
                    )
                    .overlay {
                        CardInteractionView(
                            onClick: { onActivate(card.id) },
                            onHover: { hovering in
                                if hovering {
                                    barState.hoveredCard = card.id
                                } else if barState.hoveredCard == card.id {
                                    barState.hoveredCard = nil
                                }
                            },
                            makeMenu: { onMenu(card.id) }
                        )
                    }
                }
            }
        }
        .frame(height: WindowCardView.height)
    }

    private var permissionState: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.permission == .revoked ? "Accessibility permission was revoked" : "Accessibility permission required")
                    .font(.system(size: 13, weight: .semibold))
                Text("ContextDock needs it to list windows and switch to them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Grant Access…") { onRequestPermission() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: Self.minimumWidth, minHeight: WindowCardView.height)
    }

    private func statusRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: Self.minimumWidth, minHeight: WindowCardView.height)
    }

    /// Width the bar wants for a given number of cards (before capping to the screen).
    static func preferredWidth(cardCount: Int) -> CGFloat {
        guard cardCount > 0 else { return minimumWidth + 2 * padding }
        let cards = CGFloat(cardCount) * WindowCardView.width + CGFloat(cardCount - 1) * spacing
        return cards + 2 * padding
    }

    static var preferredHeight: CGFloat { WindowCardView.height + 2 * padding }
}
