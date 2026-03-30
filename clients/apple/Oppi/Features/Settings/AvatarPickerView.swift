import SwiftUI
import UIKit

/// Sheet for picking an assistant avatar — built-in options + emoji/Genmoji input.
struct AvatarPickerView: View {
    @Binding var avatar: AssistantAvatar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                builtinSection
                emojiSection
            }
            .navigationTitle("Assistant Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var builtinSection: some View {
        Section("Built-in") {
            ForEach(Array(AssistantAvatar.builtinCases.enumerated()), id: \.offset) { _, option in
                builtinRow(option)
            }
        }
    }

    private func builtinRow(_ option: AssistantAvatar) -> some View {
        Button {
            avatar = option
            AssistantAvatar.setCurrent(option)
            SessionGridBadgeView.clearCache()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AssistantAvatarPreview(avatar: option, sessionId: "avatar-picker-\(option.displayName)", size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.themeFg)

                    if let description = option.pickerDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }

                Spacer()

                if avatar == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.themeGreen)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var emojiSection: some View {
        Section {
            EmojiInputRow(onSelect: { selectedEmoji in
                avatar = .emoji(selectedEmoji)
                AssistantAvatar.setCurrent(.emoji(selectedEmoji))
                SessionGridBadgeView.clearCache()
                dismiss()
            }, onSelectGenmoji: { data in
                if #available(iOS 18.0, *) {
                    avatar = .genmoji(data)
                    AssistantAvatar.setCurrent(.genmoji(data))
                    SessionGridBadgeView.clearCache()
                    dismiss()
                }
            })
        } footer: {
            emojiFooter
        }
    }

    @ViewBuilder
    private var emojiFooter: some View {
        if #available(iOS 18.0, *) {
            Text("Tap the field to open the emoji keyboard. Genmoji are supported.")
        } else {
            Text("Tap the field to open the emoji keyboard.")
        }
    }
}

// MARK: - Emoji Input Row

/// A row with a UITextField that opens the emoji keyboard.
/// Detects both regular emoji and Genmoji (iOS 18+).
private struct EmojiInputRow: View {
    let onSelect: (String) -> Void
    let onSelectGenmoji: (Data) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.themeComment.opacity(0.10))
                Image(systemName: "face.smiling")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.themeBlue)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Emoji or Genmoji")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.themeFg)
                Text("Choose a custom assistant badge")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            Spacer()

            EmojiTextField(onSelect: onSelect, onSelectGenmoji: onSelectGenmoji)
                .frame(width: 44, height: 44)
                .background(Color.themeComment.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.vertical, 2)
    }
}

struct AssistantAvatarPreview: View {
    let avatar: AssistantAvatar
    var sessionId: String = "assistant-avatar-preview"
    var size: CGFloat = 28

    var body: some View {
        Image(uiImage: AssistantAvatarRenderer.render(avatar: avatar, sessionId: sessionId, size: size * 2))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .background(Color.themeComment.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

// MARK: - UIKit Emoji/Genmoji Input

/// UITextView-backed input that forces the emoji keyboard and detects Genmoji.
/// Uses UITextView (not UITextField) because supportsAdaptiveImageGlyph
/// is only available on UITextView.
private struct EmojiTextField: UIViewRepresentable {
    let onSelect: (String) -> Void
    let onSelectGenmoji: (Data) -> Void

    func makeUIView(context: Context) -> EmojiUITextView {
        let view = EmojiUITextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 28)
        view.textAlignment = .center
        view.backgroundColor = .clear
        view.tintColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.maximumNumberOfLines = 1

        if #available(iOS 18.0, *) {
            view.supportsAdaptiveImageGlyph = true
        }

        return view
    }

    func updateUIView(_ uiView: EmojiUITextView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onSelectGenmoji: onSelectGenmoji)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let onSelect: (String) -> Void
        let onSelectGenmoji: (Data) -> Void

        init(onSelect: @escaping (String) -> Void, onSelectGenmoji: @escaping (Data) -> Void) {
            self.onSelect = onSelect
            self.onSelectGenmoji = onSelectGenmoji
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let attrText = textView.attributedText, attrText.length > 0 else { return }

            // Check for Genmoji (iOS 18+)
            if #available(iOS 18.0, *) {
                let range = NSRange(location: 0, length: attrText.length)
                var foundGenmoji = false
                attrText.enumerateAttribute(
                    .adaptiveImageGlyph,
                    in: range,
                    options: []
                ) { value, _, stop in
                    if let glyph = value as? NSAdaptiveImageGlyph {
                        self.onSelectGenmoji(glyph.imageContent)
                        foundGenmoji = true
                        stop.pointee = true
                    }
                }
                if foundGenmoji {
                    textView.text = ""
                    return
                }
            }

            // Regular emoji — take the first character
            let text = textView.text ?? ""
            if let first = text.first {
                onSelect(String(first))
                textView.text = ""
            }
        }
    }
}

/// UITextView subclass that always shows the emoji keyboard.
private final class EmojiUITextView: UITextView {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            if mode.primaryLanguage == "emoji" {
                return mode
            }
        }
        return super.textInputMode
    }

    override var textInputContextIdentifier: String? { "emoji" }
}
