import SwiftUI

struct BadgePickerView: View {
    let heading: String
    @State var badge: Badge?
    @State var color: ColorToken
    @State private var customEmoji = ""
    var onApply: (Badge?, ColorToken) -> Void
    var onCancel: () -> Void

    static let emojis = ["🎮", "🎵", "🧪", "🚀", "🐛", "🔥", "⭐️", "🧱", "🛠️", "📦", "🌱", "💡", "🎯", "🧭", "🔬", "📝"]
    static let symbols = ["hammer.fill", "terminal.fill", "gamecontroller.fill", "music.note", "flask.fill", "ant.fill", "star.fill", "flag.fill", "bolt.fill", "leaf.fill", "gearshape.fill", "book.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.headline).lineLimit(1)
            Text("Emoji").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 4) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    cell(selected: badge == .emoji(emoji)) { Text(emoji).font(.system(size: 16)) } action: { badge = .emoji(emoji) }
                }
            }
            HStack {
                TextField("Custom emoji or text", text: $customEmoji)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyCustom() }
                Button("Use") { applyCustom() }.disabled(customEmoji.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Symbol").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 4) {
                ForEach(Self.symbols, id: \.self) { name in
                    cell(selected: badge == .symbol(name)) { Image(systemName: name).font(.system(size: 13)) } action: { badge = .symbol(name) }
                }
            }
            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(ColorToken.allCases, id: \.self) { token in
                    Button { color = token } label: {
                        ZStack {
                            Circle().fill(token.color ?? Color.primary.opacity(0.1)).frame(width: 20, height: 20)
                            if token == .none { Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
                            if color == token { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 24, height: 24) }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(token.displayName)
                    .accessibilityLabel("Color \(token.displayName)")
                }
            }
            HStack {
                Button("Remove Badge") { badge = nil }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(badge, color) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func applyCustom() {
        let trimmed = customEmoji.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        badge = .emoji(String(trimmed.prefix(2)))
    }

    private func cell<Label: View>(selected: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
