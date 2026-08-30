import AppKit
import Foundation

extension FontPreferenceStore.CodeFontFamily {
    fileprivate func macPostScriptName(weight: NSFont.Weight) -> String? {
        guard let prefix = fontNamePrefix else { return nil }
        let suffix: String
        switch weight {
        case .bold:
            suffix = "Bold"
        case .semibold:
            suffix = self == .sourceCodePro ? "Semibold" : "SemiBold"
        default:
            suffix = "Regular"
        }
        return "\(prefix)-\(suffix)"
    }

    fileprivate func macFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let name = macPostScriptName(weight: weight),
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension FontPreferenceStore {
    static func macCodeFont(weight: NSFont.Weight = .regular) -> NSFont {
        codeFont.macFont(
            size: CGFloat(codePointSize(baseSize: 11)),
            weight: weight
        )
    }

    static func macMessageFont(
        forTextStyle textStyle: NSFont.TextStyle,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let baseSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        let size = CGFloat(messagePointSize(baseSize: Double(baseSize)))
        if useMonoForMessages {
            return codeFont.macFont(size: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

/// macOS syntax-highlighted attributed text adapter.
///
/// Token ranges come from OppiCore's shared provider (`TreeSitterHighlighter`
/// with `SyntaxTokenScanner` fallback). Colors, fonts, and gutters stay here.
enum MacSyntaxHighlighter {
    static func color(for kind: SyntaxTokenKind) -> NSColor? {
        let syntax = ThemeRuntimeState.currentThemeID().appTheme.syntax
        switch kind {
        case .variable:
            return nil
        case .comment:
            return NSColor(syntax.comment)
        case .keyword:
            return NSColor(syntax.keyword)
        case .string:
            return NSColor(syntax.string)
        case .number:
            return NSColor(syntax.number)
        case .type:
            return NSColor(syntax.type)
        case .punctuation:
            return NSColor(syntax.punctuation)
        case .function:
            return NSColor(syntax.function)
        case .operator:
            return NSColor(syntax.operator)
        }
    }

    static func attributedCode(
        _ code: String,
        language: SyntaxLanguage?,
        includeLineNumbers: Bool = true
    ) -> NSAttributedString {
        let source = SyntaxTokenScanner.truncatedCode(code)
        let theme = ThemeRuntimeState.currentThemeID().appTheme
        let plainColor = NSColor(theme.syntax.plain)
        let gutterColor = NSColor(theme.text.tertiary)
        let defaultFont = FontPreferenceStore.macCodeFont()
        let lineNumberFont = defaultFont
        let result = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")
        let lineNumberWidth = String(lines.count).count
        var sourceLineStarts: [Int] = []
        var outputLineStarts: [Int] = []
        var linePrefixLengths: [Int] = []
        var sourceOffset = 0

        sourceLineStarts.reserveCapacity(lines.count)
        outputLineStarts.reserveCapacity(lines.count)
        linePrefixLengths.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            sourceLineStarts.append(sourceOffset)
            outputLineStarts.append(result.length)

            if includeLineNumbers {
                let prefix = String(format: "%*d  ", lineNumberWidth, index + 1)
                linePrefixLengths.append(prefix.utf16.count)
                result.append(NSAttributedString(
                    string: prefix,
                    attributes: [
                        .font: lineNumberFont,
                        .foregroundColor: gutterColor,
                    ]
                ))
            } else {
                linePrefixLengths.append(0)
            }

            result.append(NSAttributedString(
                string: line,
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: plainColor,
                ]
            ))

            if index < lines.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: defaultFont,
                        .foregroundColor: plainColor,
                    ]
                ))
            }

            sourceOffset += line.utf16.count + (index < lines.count - 1 ? 1 : 0)
        }

        guard let language else { return result }
        let tokenRanges = TreeSitterHighlighter.resolvedTokenRanges(source, language: language)
        for token in tokenRanges {
            guard let color = color(for: token.kind) else { continue }
            for outputRange in outputRanges(
                for: token,
                sourceLineStarts: sourceLineStarts,
                sourceLength: source.utf16.count,
                outputLineStarts: outputLineStarts,
                linePrefixLengths: linePrefixLengths,
                outputLength: result.length
            ) {
                result.addAttribute(.foregroundColor, value: color, range: outputRange)
            }
        }

        return result
    }

    private static func outputRanges(
        for token: SyntaxTokenRange,
        sourceLineStarts: [Int],
        sourceLength: Int,
        outputLineStarts: [Int],
        linePrefixLengths: [Int],
        outputLength: Int
    ) -> [NSRange] {
        guard !sourceLineStarts.isEmpty,
              token.length > 0,
              let startLineIndex = lineIndex(for: token.location, starts: sourceLineStarts) else { return [] }

        let tokenStart = token.location
        let tokenEnd = token.location + token.length
        var ranges: [NSRange] = []
        var lineIndex = startLineIndex

        while sourceLineStarts.indices.contains(lineIndex),
              outputLineStarts.indices.contains(lineIndex),
              linePrefixLengths.indices.contains(lineIndex) {
            let lineStart = sourceLineStarts[lineIndex]
            let lineEnd = lineIndex + 1 < sourceLineStarts.count
                ? max(lineStart, sourceLineStarts[lineIndex + 1] - 1)
                : sourceLength
            let overlapStart = max(tokenStart, lineStart)
            let overlapEnd = min(tokenEnd, lineEnd)

            if overlapStart < overlapEnd {
                let locationInLine = overlapStart - lineStart
                let outputLocation = outputLineStarts[lineIndex] + linePrefixLengths[lineIndex] + locationInLine
                let outputRange = NSRange(location: outputLocation, length: overlapEnd - overlapStart)
                if outputRange.location >= 0, outputRange.location + outputRange.length <= outputLength {
                    ranges.append(outputRange)
                }
            }

            if tokenEnd <= lineEnd { break }
            lineIndex += 1
        }

        return ranges
    }

    private static func lineIndex(for location: Int, starts: [Int]) -> Int? {
        var lower = 0
        var upper = starts.count - 1
        var result = 0

        while lower <= upper {
            let mid = (lower + upper) / 2
            if starts[mid] <= location {
                result = mid
                lower = mid + 1
            } else {
                upper = mid - 1
            }
        }

        return result
    }
}
