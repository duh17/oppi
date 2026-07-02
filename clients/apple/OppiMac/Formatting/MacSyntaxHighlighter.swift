import AppKit
import Foundation

/// macOS syntax-highlighted attributed text adapter backed by OppiCore's shared
/// `SyntaxTokenScanner`.
enum MacSyntaxHighlighter {
    static func color(for kind: SyntaxTokenKind) -> NSColor? {
        switch kind {
        case .variable:
            return nil
        case .comment:
            return .secondaryLabelColor
        case .keyword:
            return .systemPurple
        case .string:
            return .systemGreen
        case .number:
            return .systemOrange
        case .type:
            return .systemBlue
        case .punctuation:
            return .tertiaryLabelColor
        case .function:
            return .systemTeal
        case .operator:
            return .systemPink
        }
    }

    static func attributedCode(
        _ code: String,
        language: SyntaxLanguage?,
        includeLineNumbers: Bool = true
    ) -> NSAttributedString {
        let source = SyntaxTokenScanner.truncatedCode(code)
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
            } else {
                linePrefixLengths.append(0)
            }

            result.append(NSAttributedString(
                string: line,
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            ))

            if index < lines.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: defaultFont,
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
            }

            sourceOffset += line.utf16.count + (index < lines.count - 1 ? 1 : 0)
        }

        guard let language else { return result }
        let tokenRanges = SyntaxTokenScanner.scanTokenRanges(source, language: language)
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
