import SwiftUI
import UIKit

struct SettingsTextPage: View {
    @State private var selectedCodeFont = FontPreferences.codeFont
    @State private var selectedCodeTextScale = FontPreferences.codeTextScale
    @State private var selectedMessageTextScale = FontPreferences.messageTextScale
    @State private var useMonoMessages = FontPreferences.useMonoForMessages

    var body: some View {
        List {
            Section {
                Picker("Code Font", selection: $selectedCodeFont) {
                    ForEach(FontPreferences.CodeFontFamily.allCases) { family in
                        Text(family.displayName)
                            .tag(family)
                    }
                }
                .onChange(of: selectedCodeFont) { _, newValue in
                    FontPreferences.setCodeFont(newValue)
                }
            } footer: {
                Text("Nerd Font icons add prompt and file icons in the terminal and tool output, with any code font.")
            }

            Section {
                TextScaleSliderRow(
                    title: "Code Text Size",
                    scale: $selectedCodeTextScale,
                    range: FontPreferences.minimumCodeTextScale...FontPreferences.maximumCodeTextScale
                )
                .onChange(of: selectedCodeTextScale) { _, newValue in
                    FontPreferences.setCodeTextScale(CGFloat(newValue))
                }
            } footer: {
                Text("Code blocks, diffs, terminals, and tool output.")
            }

            Section {
                TextScaleSliderRow(
                    title: "Message Text Size",
                    scale: $selectedMessageTextScale,
                    range: FontPreferences.minimumMessageTextScale...FontPreferences.maximumMessageTextScale
                )
                .onChange(of: selectedMessageTextScale) { _, newValue in
                    FontPreferences.setMessageTextScale(CGFloat(newValue))
                }

                Toggle("Monospaced Messages", isOn: $useMonoMessages)
                    .onChange(of: useMonoMessages) { _, newValue in
                        FontPreferences.setUseMonoForMessages(newValue)
                    }
            } footer: {
                Text("Assistant and user chat messages. Monospaced Messages sets them in your code font.")
            }

            Section {
                TypographyPreviewCard(
                    codeFont: selectedCodeFont,
                    codeTextScale: selectedCodeTextScale,
                    messageTextScale: selectedMessageTextScale,
                    useMonoMessages: useMonoMessages
                )
            }
        }
        .settingsPage("Text")
    }
}

private struct TextScaleSliderRow: View {
    let title: String
    @Binding var scale: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text("\(percent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }

            Slider(value: $scale, in: range, step: 0.05) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityValue("\(percent) percent")
        }
    }

    private var percent: Int { Int(round(scale * 100)) }
}

private struct TypographyPreviewCard: View {
    let codeFont: FontPreferences.CodeFontFamily
    let codeTextScale: CGFloat
    let messageTextScale: CGFloat
    let useMonoMessages: Bool

    private var codePreviewPointSize: CGFloat {
        FontPreferences.codePointSize(baseSize: 11, codeTextScale: codeTextScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Preview", systemImage: "text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)

            VStack(alignment: .leading, spacing: 6) {
                Text("Code and tool output")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Text("let files = try await workspace.changedFiles()\nprint(files.count)")
                    .font(previewFont(size: codePreviewPointSize, uiWeight: .regular))
                    .foregroundStyle(.themeFg)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Assistant message")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Text("I found the settings path and kept the global preference device-local.")
                    .font(messagePreviewFont)
                    .foregroundStyle(.themeFg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.themeBgHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var messagePreviewFont: Font {
        let pointSize = FontPreferences.messagePointSize(
            baseSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            messageTextScale: messageTextScale
        )
        guard useMonoMessages else { return .system(size: pointSize) }
        return previewFont(size: pointSize, uiWeight: .regular)
    }

    private func previewFont(size: CGFloat, uiWeight: UIFont.Weight) -> Font {
        if let postScriptName = codeFont.postScriptName(weight: uiWeight) {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size, design: .monospaced)
    }
}
