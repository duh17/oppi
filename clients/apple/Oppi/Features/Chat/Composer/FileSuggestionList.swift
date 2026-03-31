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
                Group {
                    if suggestion.isDirectory {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.themeYellow)
                    } else {
                        let icon = FileIcon.forPath(suggestion.path)
                        Image(systemName: icon.symbolName)
                            .foregroundStyle(icon.color)
                    }
                }
                .font(.caption)
                .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    if suggestion.matchPositions.isEmpty {
                        Text(suggestion.displayName)
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                    } else {
                        HighlightedSuggestionText(
                            path: suggestion.path,
                            matchPositions: suggestion.matchPositions,
                            isDirectory: suggestion.isDirectory
                        )
                        .lineLimit(1)
                    }

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

// MARK: - Highlighted Suggestion Text

/// Renders just the filename with matched characters highlighted.
/// Match positions are full-path indices — only those within the filename range are shown.
private struct HighlightedSuggestionText: View {
    let path: String
    let matchPositions: [Int]
    let isDirectory: Bool

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        let normalizedPath = (isDirectory && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let scalars = Array(normalizedPath.unicodeScalars)

        // Find where the filename starts (after the last `/`)
        let filenameOffset: Int
        if let lastSlash = scalars.lastIndex(of: "/") {
            filenameOffset = lastSlash + 1
        } else {
            filenameOffset = 0
        }

        let filenameScalars = Array(scalars[filenameOffset...])
        let matchSet = Set(matchPositions.compactMap { pos -> Int? in
            let adjusted = pos - filenameOffset
            guard adjusted >= 0, adjusted < filenameScalars.count else { return nil }
            return adjusted
        })

        var result = AttributedString()
        var i = 0
        while i < filenameScalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < filenameScalars.count, matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(filenameScalars[i...end])))
                segment.foregroundColor = .themeYellow
                segment.font = .system(.subheadline, design: .monospaced).bold()
                result.append(segment)
                i = end + 1
            } else {
                var end = i
                while end + 1 < filenameScalars.count, !matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(filenameScalars[i...end])))
                segment.foregroundColor = .themeFgDim
                segment.font = .system(.subheadline, design: .monospaced)
                result.append(segment)
                i = end + 1
            }
        }

        return result
    }
}
