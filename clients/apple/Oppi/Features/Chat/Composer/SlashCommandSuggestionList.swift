import SwiftUI

struct SlashCommandSuggestionList: View {
    let suggestions: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    private let maxPanelHeight: CGFloat = 260
    private let panelCornerRadius: CGFloat = 12

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: suggestions.count > 5) {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                    Button {
                        onSelect(command)
                    } label: {
                        row(for: command)
                    }
                    .buttonStyle(.plain)

                    if index < suggestions.count - 1 {
                        Divider()
                            .overlay(Color.themeComment.opacity(0.18))
                    }
                }
            }
        }
        .frame(maxHeight: maxPanelHeight)
        .background(Color.themeBgDark, in: panelShape)
        .overlay(panelShape.stroke(Color.themeComment.opacity(0.22), lineWidth: 1))
        .clipShape(panelShape)
    }

    private func row(for command: SlashCommand) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.source.iconName)
                .font(.caption)
                .foregroundStyle(command.source.iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(command.invocation)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(.themeBlue)

                    Spacer(minLength: 4)

                    Text(command.source.label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.themeComment)
                }

                if let description = command.description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
