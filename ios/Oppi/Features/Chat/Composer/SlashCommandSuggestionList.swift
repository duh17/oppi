import SwiftUI

struct SlashCommandSuggestionList: View {
    let suggestions: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                Button {
                    onSelect(command)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command.invocation)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .foregroundStyle(.themeBlue)

                            Spacer(minLength: 4)

                            Text(command.source.label)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeComment)
                        }

                        if let description = command.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if index < suggestions.count - 1 {
                    Divider()
                        .overlay(Color.themeComment.opacity(0.18))
                }
            }
        }
        .background(Color.themeBgDark, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.themeComment.opacity(0.22), lineWidth: 1)
        )
    }
}
