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
            HStack {
                Text(option.displayName)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.themeFg)
                Spacer()
                if avatar == option {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.themeGreen)
                }
            }
        }
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
        HStack {
            Text("Pick emoji")
                .foregroundStyle(.themeComment)
            Spacer()
            EmojiTextField(onSelect: onSelect, onSelectGenmoji: onSelectGenmoji)
                .frame(width: 44, height: 44)
        }
    }
}

// MARK: - UIKit Emoji TextField

/// UITextField that forces the emoji keyboard and detects Genmoji.
private struct EmojiTextField: UIViewRepresentable {
    let onSelect: (String) -> Void
    let onSelectGenmoji: (Data) -> Void

    func makeUIView(context: Context) -> EmojiUITextField {
        let field = EmojiUITextField()
        field.delegate = context.coordinator
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 28)
        field.placeholder = "😊"
        field.tintColor = .clear // hide cursor

        // Enable Genmoji on iOS 18+
        if #available(iOS 18.0, *) {
            field.supportsAdaptiveImageGlyph = true
        }

        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )

        return field
    }

    func updateUIView(_ uiView: EmojiUITextField, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onSelectGenmoji: onSelectGenmoji)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let onSelect: (String) -> Void
        let onSelectGenmoji: (Data) -> Void

        init(onSelect: @escaping (String) -> Void, onSelectGenmoji: @escaping (Data) -> Void) {
            self.onSelect = onSelect
            self.onSelectGenmoji = onSelectGenmoji
        }

        @objc func textDidChange(_ textField: UITextField) {
            // Check for Genmoji first (iOS 18+)
            if #available(iOS 18.0, *),
               let attrText = textField.attributedText {
                let range = NSRange(location: 0, length: attrText.length)
                var foundGenmoji = false
                attrText.enumerateAttribute(
                    .adaptiveImageGlyph,
                    in: range,
                    options: []
                ) { value, _, stop in
                    if let glyph = value as? NSAdaptiveImageGlyph {
                        onSelectGenmoji(glyph.imageContent)
                        foundGenmoji = true
                        stop.pointee = true
                    }
                }
                if foundGenmoji {
                    textField.text = ""
                    return
                }
            }

            // Regular emoji
            guard let text = textField.text, !text.isEmpty else { return }
            // Take just the first character/emoji
            if let first = text.first {
                let emoji = String(first)
                onSelect(emoji)
                textField.text = ""
            }
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Allow the change — we handle it in textDidChange
            true
        }
    }
}

/// UITextField subclass that always shows the emoji keyboard.
private final class EmojiUITextField: UITextField {
    override var textInputMode: UITextInputMode? {
        // Find the emoji input mode
        for mode in UITextInputMode.activeInputModes {
            if mode.primaryLanguage == "emoji" {
                return mode
            }
        }
        return super.textInputMode
    }

    override var textInputContextIdentifier: String? { "emoji" }
}
