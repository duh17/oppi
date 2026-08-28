import Foundation

/// Platform-neutral projection of transport/user-message text for timeline matching.
///
/// Composer-only attachment metadata can be prepended as an `[[oppi-attachments:...]]`
/// marker or appended as plain-text file reference blocks. The reducer only needs
/// the user-visible text when deduping optimistic messages against trace history.
enum UserMessageTextProjection {
    private static let markerPrefix = "[[oppi-attachments:"
    private static let markerSuffix = "]]"
    static let referenceBlockHeader = "Referenced workspace files:"
    static let attachedFilesHeader = "Attached files:"
    static let selectedCommitHeader = "Selected commit:"

    static func comparableText(_ rawText: String) -> String {
        let visible = visibleText(from: rawText)
        guard visible.hasPrefix("/skill:") else { return visible }
        return visible
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func visibleText(from rawText: String) -> String {
        let content = rawText.trimmingCharacters(in: .newlines)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let withoutMarker = stripMarker(from: content)
        let withoutAttachedFiles = splitTrailingAttachedFilesBlock(from: withoutMarker)?.visibleText
            ?? withoutMarker
        let withoutCommitBlock = splitTrailingSelectedCommitBlock(from: withoutAttachedFiles)?.visibleText
            ?? withoutAttachedFiles
        let withoutReferenceBlock = splitTrailingReferenceBlock(from: withoutCommitBlock)?.visibleText
            ?? withoutCommitBlock
        return collapseLeadingSkillBlock(
            in: withoutReferenceBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Pi expands `/skill:name` into a leading `<skill>` block before history reload.
    /// Keep the compact command visible without rewriting the stored XML.
    static func collapseLeadingSkillBlock(in text: String) -> String {
        let prefix = "<skill name=\""
        guard text.hasPrefix(prefix) else { return text }

        let afterPrefix = text.dropFirst(prefix.count)
        guard let nameEnd = afterPrefix.firstIndex(of: "\"") else { return text }
        let name = String(afterPrefix[..<nameEnd])
        guard !name.isEmpty else { return text }

        var cursor = afterPrefix[afterPrefix.index(after: nameEnd)...]
        let locationPrefix = " location=\""
        guard cursor.hasPrefix(locationPrefix) else { return text }
        cursor = cursor.dropFirst(locationPrefix.count)
        guard let locationEnd = cursor.firstIndex(of: "\"") else { return text }
        cursor = cursor[cursor.index(after: locationEnd)...]
        guard cursor.hasPrefix(">\n") else { return text }
        cursor = cursor.dropFirst(2)

        guard let closerRange = lastValidSkillCloserRange(
            in: text,
            bodyStart: cursor.startIndex
        ) else {
            return text
        }

        let trailing = text[closerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "/skill:\(name)"
        guard !trailing.isEmpty else { return command }
        return "\(command)\n\n\(trailing)"
    }

    private static func lastValidSkillCloserRange(
        in text: String,
        bodyStart: String.Index
    ) -> Range<String.Index>? {
        let closerNeedle = "\n</skill>"
        var searchEnd = text.endIndex
        while searchEnd > bodyStart {
            guard let closerStart = text.range(
                of: closerNeedle,
                options: .backwards,
                range: bodyStart..<searchEnd
            )?.lowerBound else {
                return nil
            }

            let closerEnd = text.index(closerStart, offsetBy: closerNeedle.count)
            let suffix = text[closerEnd...]
            if suffix.isEmpty {
                return closerStart..<closerEnd
            }
            if suffix.hasPrefix("\n\n") {
                return closerStart..<text.index(closerEnd, offsetBy: 2)
            }
            searchEnd = closerStart
        }
        return nil
    }

    private static func stripMarker(from text: String) -> String {
        guard let firstLineEnd = text.firstIndex(of: "\n") else {
            return markerHasVisibleMetadata(text) ? "" : text
        }

        let firstLine = String(text[..<firstLineEnd])
        guard markerHasVisibleMetadata(firstLine) else { return text }
        return String(text[text.index(after: firstLineEnd)...])
    }

    private static func markerHasVisibleMetadata(_ line: String) -> Bool {
        guard line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else { return false }

        let payloadStart = line.index(line.startIndex, offsetBy: markerPrefix.count)
        let payloadEnd = line.index(line.endIndex, offsetBy: -markerSuffix.count)
        let payload = line[payloadStart..<payloadEnd]

        for pair in payload.split(separator: ";") {
            if pair.hasPrefix("b:") {
                let body = pair.dropFirst(2)
                let pieces = body.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2,
                      isKnownBadgeKind(String(pieces[0])),
                      let count = Int(pieces[1]),
                      count > 0 else {
                    continue
                }
                return true
            }

            if pair.hasPrefix("p:") {
                let body = pair.dropFirst(2)
                let pieces = body.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2,
                      isKnownPathPillKind(String(pieces[0])),
                      let decoded = String(pieces[1]).removingPercentEncoding,
                      !decoded.isEmpty else {
                    continue
                }
                return true
            }
        }

        return false
    }

    private static func isKnownBadgeKind(_ value: String) -> Bool {
        value == "photos" || value == "uploadedFiles"
    }

    private static func isKnownPathPillKind(_ value: String) -> Bool {
        value == "uploadedFile" || value == "reviewFile" || value == "repoFile" || value == "gitCommit"
    }

    static func splitTrailingReferenceBlock(
        from text: String
    ) -> (visibleText: String, bodyLines: [String])? {
        splitTrailingBlock(header: referenceBlockHeader, from: text) { lines in
            !lines.isEmpty && lines.allSatisfy { line in
                guard line.hasPrefix("- ") else { return false }
                return !line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    static func splitTrailingSelectedCommitBlock(
        from text: String
    ) -> (visibleText: String, bodyLines: [String])? {
        splitTrailingBlock(header: selectedCommitHeader, from: text, validatesBody: isSelectedCommitBody)
    }

    static func selectedCommitSHA(from line: String) -> String? {
        let prefix = "- SHA: "
        guard line.hasPrefix(prefix) else { return nil }
        let sha = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    static func splitTrailingAttachedFilesBlock(
        from text: String
    ) -> (visibleText: String, bodyLines: [String])? {
        splitTrailingBlock(header: attachedFilesHeader, from: text) { lines in
            var hasEntry = false
            for line in lines {
                if line.hasPrefix("- ") {
                    guard attachedFilePath(from: line) != nil else { return false }
                    hasEntry = true
                    continue
                }

                let metadataPrefixes = ["  MIME: ", "  Size: "]
                guard hasEntry,
                      let prefix = metadataPrefixes.first(where: { line.hasPrefix($0) }),
                      !line.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
            }
            return hasEntry
        }
    }

    private static func isSelectedCommitBody(_ lines: [String]) -> Bool {
        let messagePrefix = "- Message: "
        guard lines.count >= 2, lines.count.isMultiple(of: 2) else { return false }
        var index = 0
        while index < lines.count {
            guard selectedCommitSHA(from: lines[index]) != nil,
                  lines[index + 1].hasPrefix(messagePrefix) else {
                return false
            }
            index += 2
        }
        return true
    }

    static func attachedFilePath(from line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        let payload = String(line.dropFirst(2))
        var candidates: [(displayName: String, path: String)] = []
        var searchStart = payload.startIndex

        while let separator = payload.range(of: ": ", range: searchStart..<payload.endIndex) {
            let displayName = String(payload[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let path = String(payload[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty, !path.isEmpty {
                candidates.append((displayName, path))
            }
            searchStart = separator.upperBound
        }

        if let storedAttachment = candidates.first(where: {
            $0.path.hasPrefix(".pi/attachments/")
        }) {
            return storedAttachment.path
        }

        return candidates.first(where: {
            ($0.path as NSString).lastPathComponent == $0.displayName
        })?.path
    }

    private static func splitTrailingBlock(
        header: String,
        from text: String,
        validatesBody: ([String]) -> Bool
    ) -> (visibleText: String, bodyLines: [String])? {
        let content = text.trimmingCharacters(in: .newlines)
        let lines = content.components(separatedBy: "\n")
        guard let headerIndex = lines.lastIndex(of: header) else {
            return nil
        }
        if headerIndex > lines.startIndex {
            let precedingLine = lines[lines.index(before: headerIndex)]
            guard precedingLine.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
        }

        let bodyStart = lines.index(after: headerIndex)
        let bodyLines = Array(lines[bodyStart...])
        guard validatesBody(bodyLines) else { return nil }

        let visibleText = lines[..<headerIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (visibleText, bodyLines)
    }
}
