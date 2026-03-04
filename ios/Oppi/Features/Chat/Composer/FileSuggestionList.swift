import SwiftUI

struct FileSuggestionList: View {
    let suggestions: [FileSuggestion]
    let onSelect: (FileSuggestion) -> Void

    private let maxPanelHeight: CGFloat = 260
    private let panelCornerRadius: CGFloat = 12

    var body: some View {
        ScrollView(.vertical, showsIndicators: suggestions.count > 5) {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    row(for: suggestion)

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

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    private func row(for suggestion: FileSuggestion) -> some View {
        Button {
            onSelect(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder" : "doc")
                    .font(.caption)
                    .foregroundStyle(suggestion.isDirectory ? .themeYellow : .themeComment)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.displayName)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    if let parentPath = suggestion.parentPath {
                        Text(parentPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }
}
