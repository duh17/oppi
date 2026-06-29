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

    static func comparableText(_ rawText: String) -> String {
        visibleText(from: rawText)
    }

    static func visibleText(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withoutMarker = stripMarker(from: trimmed)
        let withoutAttachedFiles = stripBlock(header: attachedFilesHeader, from: withoutMarker)
        let withoutReferenceBlock = stripBlock(header: referenceBlockHeader, from: withoutAttachedFiles)
        return withoutReferenceBlock.trimmingCharacters(in: .whitespacesAndNewlines)
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
        value == "uploadedFile" || value == "reviewFile" || value == "repoFile"
    }

    private static func stripBlock(header: String, from text: String) -> String {
        guard let range = text.range(of: header) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
