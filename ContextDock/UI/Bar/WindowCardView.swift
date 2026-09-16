import AppKit
import SwiftUI

/// One window card: app icon (primary identity) with an optional small badge, a two-line
/// label, and distinct hover / active / keyboard-selected visual states.
struct WindowCardView: View {
    static let width: CGFloat = 190
    static let height: CGFloat = 56

    let card: CardViewModel
    let icon: NSImage?
    let isHovered: Bool
    let isKeyboardSelected: Bool
    var isDropTarget: Bool = false
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 13, weight: card.hasCustomName ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.width, height: Self.height)
        .background(background)
        .overlay(alignment: .leading) {
            if let color = card.colorToken.color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isKeyboardSelected || isDropTarget ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(card.isMinimized || card.isAppHidden ? 0.6 : 1)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var iconView: some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 22))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
            if let badge = card.badge {
                badgeView(badge)
                    .offset(x: 5, y: 5)
            } else if card.isMinimized {
                Image(systemName: "arrow.down.right.circle.fill")
                    .font(.system(size: 11))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .secondary)
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private func badgeView(_ badge: Badge) -> some View {
        switch badge.kind {
        case .emoji:
            Text(badge.value)
                .font(.system(size: 12))
                .padding(1)
                .background(Circle().fill(.background))
        case .symbol:
            Image(systemName: badge.value)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(card.colorToken.color ?? .accentColor)
                .padding(3)
                .background(Circle().fill(.background))
        }
    }

    private var background: some ShapeStyle {
        if isDropTarget {
            return AnyShapeStyle(Color.accentColor.opacity(0.3))
        }
        if card.isActive {
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.28 : 0.2))
        }
        if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.1))
        }
        return AnyShapeStyle(Color.primary.opacity(0.04))
    }

    private var borderColor: Color {
        if isKeyboardSelected || isDropTarget { return .accentColor }
        if card.isActive { return Color.accentColor.opacity(0.6) }
        return Color.primary.opacity(0.08)
    }

    private var tooltip: String {
        var lines: [String] = []
        lines.append("\(card.applicationName)")
        if let raw = card.rawTitle { lines.append("Title: \(raw)") }
        if let project = card.context.projectDisplayName { lines.append("Project: \(project)") }
        if let path = card.context.projectPath { lines.append("Path: \(path)") }
        if card.isStale { lines.append("Information may be outdated") }
        lines.append("Drag onto another card to group")
        return lines.joined(separator: "\n")
    }
}
