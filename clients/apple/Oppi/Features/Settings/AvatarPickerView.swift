import SwiftUI

/// Assistant adapter for the shared icon/avatar picker interaction.
struct AvatarPickerView: View {
    @Binding var avatar: AssistantAvatar

    var body: some View {
        UnifiedIconPickerView(
            purpose: .assistant,
            savedValue: avatar,
            defaultValue: .piText,
            builtinOptions: [
                IconPickerOption(
                    id: "officialPi",
                    label: AssistantAvatar.officialPi.displayName,
                    detail: AssistantAvatar.officialPi.pickerDescription,
                    value: .officialPi
                ),
                IconPickerOption(
                    id: "golGrid",
                    label: AssistantAvatar.golGrid.displayName,
                    detail: AssistantAvatar.golGrid.pickerDescription,
                    value: .golGrid
                ),
            ],
            symbols: [],
            makeEmoji: AssistantAvatar.emoji,
            makeSymbol: nil,
            customChoice: Self.customChoice,
            preview: { value, size in
                AnyView(AssistantAvatarPreview(
                    avatar: value,
                    sessionId: "assistant-avatar-picker",
                    size: size
                ))
            },
            genmojiPreview: { data, contentDescription, size in
                AnyView(AssistantAvatarPreview(
                    avatar: .genmoji(data: data, contentDescription: contentDescription),
                    sessionId: "assistant-avatar-picker-genmoji",
                    size: size
                ))
            },
            prepareGenmoji: { data, contentDescription in
                try AssistantAvatar.prepareForPersistence(
                    .genmoji(data: data, contentDescription: contentDescription)
                )
            },
            commit: { selected in
                try Self.persist(selected, to: $avatar)
            },
            accessibilityPrefix: "assistant.avatarPicker"
        )
    }

    @MainActor
    static func persist(_ selected: AssistantAvatar, to binding: Binding<AssistantAvatar>) throws {
        let persisted = try AssistantAvatar.setCurrent(selected)
        binding.wrappedValue = persisted
    }

    private static func customChoice(_ avatar: AssistantAvatar) -> IconPickerCustomChoice? {
        switch avatar {
        case .emoji(let emoji): return .emoji(emoji)
        case .genmoji(_, let contentDescription): return .genmoji(contentDescription)
        case .officialPi, .piText, .golGrid: return nil
        }
    }
}

struct CurrentAssistantAvatarPreview: View {
    let sessionId: String
    let size: CGFloat
    @State private var avatar = AssistantAvatar.current

    var body: some View {
        AssistantAvatarPreview(avatar: avatar, sessionId: sessionId, size: size)
            .onReceive(NotificationCenter.default.publisher(for: .assistantAvatarDidChange)) { _ in
                avatar = AssistantAvatar.current
            }
    }
}

struct AssistantAvatarPreview: View {
    let avatar: AssistantAvatar
    var sessionId: String = "assistant-avatar-preview"
    var size: CGFloat = 28

    @Environment(\.themeID) private var themeID

    var body: some View {
        Image(
            uiImage: AssistantAvatarRenderer.render(
                avatar: avatar,
                sessionId: sessionId,
                size: size * 2,
                themeID: themeID
            )
        )
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
        .background(
            Color.themeComment.opacity(0.10),
            in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        )
        .accessibilityHidden(true)
    }
}
