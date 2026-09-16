import AppKit
import SwiftUI

/// A group card: name line, member count, and a row of member icons. Clicking an icon
/// switches to that member only; clicking elsewhere opens the whole group.
struct GroupCardView: View {
    let group: GroupViewModel
    let icon: (WindowSessionID) -> NSImage?
    let isHovered: Bool
    let isKeyboardSelected: Bool
    let isDropTarget: Bool
    let reduceMotion: Bool
    var memberOverlay: (CardViewModel) -> AnyView

    static let maxVisibleMembers = 5

    var body: some View {
        HStack(spacing: 10) {
            memberIcons
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(group.colorToken.color ?? .secondary)
                    Text(group.title)
                        .font(.system(size: 13, weight: group.hasCustomName ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let badge = group.badge { badgeView(badge) }
                }
                Text(group.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: WindowCardView.width, height: WindowCardView.height)
        .background(background)
        .overlay(alignment: .leading) {
            if let color = group.colorToken.color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10).padding(.leading, 3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isKeyboardSelected || isDropTarget ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .help(tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.accessibilityLabel)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var memberIcons: some View {
        let visible = Array(group.members.prefix(Self.maxVisibleMembers))
        let hidden = group.members.count - visible.count
        return HStack(spacing: -6) {
            ForEach(visible) { member in
                ZStack {
                    Circle().fill(.background).frame(width: 26, height: 26)
                    if let image = icon(member.id) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    if member.isActive {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 26, height: 26)
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(memberOverlay(member))
                .help("\(member.applicationName): \(member.title)")
                .accessibilityLabel("\(member.applicationName), \(member.title)")
                .accessibilityAddTraits(.isButton)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func badgeView(_ badge: Badge) -> some View {
        switch badge.kind {
        case .emoji: Text(badge.value).font(.system(size: 11))
        case .symbol: Image(systemName: badge.value).font(.system(size: 10, weight: .bold)).foregroundStyle(group.colorToken.color ?? .accentColor)
        }
    }

    private var background: some ShapeStyle {
        if isDropTarget { return AnyShapeStyle(Color.accentColor.opacity(0.3)) }
        if group.isActive { return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.28 : 0.2)) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.1)) }
        return AnyShapeStyle(Color.primary.opacity(0.06))
    }

    private var borderColor: Color {
        if isDropTarget || isKeyboardSelected { return .accentColor }
        if group.isActive { return Color.accentColor.opacity(0.6) }
        return Color.primary.opacity(0.12)
    }

    private var tooltip: String {
        (["Group: \(group.title)"] + group.members.map { "• \($0.applicationName): \($0.rawTitle ?? $0.title)" }).joined(separator: "\n")
    }
}
