import UIKit

/// A user-role input another session sent (a subagent's report, the task it was
/// handed at spawn, or a `session_send` message), as the timeline draws it: a
/// card that names the sender and folds a long message behind a short preview.
///
/// The row is `UserTimelineRowContentView` — an agent message is a user message
/// with speaker chrome and a fold, so it reuses that row's Markdown body rather
/// than a second renderer. This type owns the facts the row and the timeline
/// share: the fold state and the folded preview. Who sent it and what it is come
/// from `MessageOrigin`, which the Session Outline reads too.
struct AgentMessageCard {
    /// Lines the collapsed card shows before it stops.
    static let collapsedLineLimit = 3
    /// Source lines read before the fold stops reading and calls the message long.
    static let previewSourceLineCap = 40
    /// Source characters read before the same cap applies.
    static let previewSourceCharacterCap = 4_096
    /// What the folded card keeps: enough to fill its lines and no more, so the
    /// label and its spoken text never carry a whole report.
    static let previewLineCap = 12
    static let previewCharacterCap = 800

    let origin: MessageOrigin
    /// The message as plain text for the folded card, derived from the same
    /// Markdown the expanded card renders, so no `#` marker or `|---|` divider
    /// reaches the preview. Already limited to what the folded card shows.
    let preview: String
    /// The reader opened the card. Only meaningful when `canExpand`.
    let isExpanded: Bool
    /// The message needs more than the preview's lines. Decided at the row's
    /// width when the row is configured; a message that fits is shown whole and
    /// has no fold.
    let canExpand: Bool
    /// Asked when the card is tapped or its header is activated.
    var onToggleExpand: (() -> Void)?
    /// Asked when the sender's name is tapped.
    var onOpenSender: (() -> Void)?
    /// The sending session's launch snapshot, as the client's session store holds
    /// it. Its saved Agent gives the header the same icon an assistant row draws for
    /// that session; nil, or a session with no Agent, draws the same global avatar an
    /// assistant row shows for a session launched without one. Resolved when the row
    /// is configured, so a sender the store learns later reaches the card on the row's
    /// next configure, not on a store change of its own.
    var sender: SessionLaunchMetadata? = nil

    /// False only for a long message the reader has not opened.
    var showsWholeMessage: Bool { !canExpand || isExpanded }

    /// What the header's identity slot draws: the sender's Agent icon, or the global
    /// avatar when the sender is unknown or launched without an Agent. One precedence
    /// rule, shared with assistant rows and the empty chat.
    var senderIdentity: AssistantIdentityPresentation {
        AssistantIdentityPresentation.resolve(
            agentId: sender?.agentId,
            agentIcon: sender?.agentIcon
        )
    }

    // MARK: - Fold

    /// What reading a message for the folded card produced.
    struct Preview: Equatable {
        let text: String
        /// Reading stopped before the message ended, so it is certainly longer
        /// than the folded card's lines.
        let isTruncated: Bool
    }

    /// Whether the message is taller than the folded card's line budget at the
    /// width it is drawn.
    static func canExpand(preview: String, width: CGFloat, font: UIFont) -> Bool {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // More lines than the budget can never fit, and deciding that without
        // measuring keeps a long report's preview cheap on every configure.
        let lineCount = trimmed.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        guard lineCount <= collapsedLineLimit else { return true }
        let height = (trimmed as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return height > font.lineHeight * CGFloat(collapsedLineLimit) + 1
    }

    /// The folded card's text for a Markdown message: structure markers that only
    /// mean something once rendered are gone, and a table keeps its cells as rows
    /// of text instead of its pipes.
    ///
    /// This is a line-level reading, not a second Markdown parser: the expanded
    /// card is the source of truth and this preview only has to be readable.
    /// Emphasis markers are left alone on purpose, because reports carry glob
    /// patterns and `snake_case` identifiers that would read worse without them.
    /// Reading stops at `previewSourceLineCap` lines, `previewSourceCharacterCap`
    /// characters, or the display cap, whichever comes first.
    static func preview(forMarkdown markdown: String) -> Preview {
        var lines: [String] = []
        var consumedCharacters = 0
        var isTruncated = false
        var insideFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            consumedCharacters += rawLine.count + 1
            if lines.count >= previewSourceLineCap
                || consumedCharacters > previewSourceCharacterCap {
                isTruncated = true
                break
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isFence(line) {
                insideFence.toggle()
                continue
            }
            lines.append(insideFence ? line : plainLineText(line))
        }

        let tables = tableLineIndexes(in: lines)
        var renderedLines: [String] = []
        renderedLines.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if tables.isDivider.contains(index) {
                continue
            }
            if tables.isContent.contains(index) {
                renderedLines.append(tableRowText(line))
                continue
            }
            renderedLines.append(line)
        }

        let display = capping(joiningPreviewLines(renderedLines))
        return Preview(text: display.text, isTruncated: isTruncated || display.didCut)
    }

    /// A line's text without the markers of the block it belongs to.
    private static func plainLineText(_ line: String) -> String {
        var text = line
        if text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = removingHeadingMarker(text)
        text = replacingListMarker(text)
        text = removingInlineMarkers(text)
        return text
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func removingHeadingMarker(_ line: String) -> String {
        var markerCount = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", markerCount < 6 {
            markerCount += 1
            index = line.index(after: index)
        }
        guard markerCount > 0 else { return line }
        // `#tag` is not a heading; CommonMark wants a space after the markers.
        guard index == line.endIndex || line[index] == " " else { return line }
        return String(line[index...]).trimmingCharacters(in: .whitespaces)
    }

    private static func replacingListMarker(_ line: String) -> String {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return "\u{2022} " + rest
        }
        return line
    }

    private static func removingInlineMarkers(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "`", with: "")
        text = replacingLinks(text)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        return text
    }

    /// `[text](url)`, `[text][ref]`, and `![alt](url)` keep their visible words.
    private static func replacingLinks(_ line: String) -> String {
        var result = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "[") {
            result += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else {
                result += rest[open...]
                return result
            }
            let label = rest[afterOpen..<close]
            let afterClose = rest.index(after: close)
            let target: Substring
            if afterClose < rest.endIndex, rest[afterClose] == "(" {
                guard let end = rest[rest.index(after: afterClose)...].firstIndex(of: ")") else {
                    result += rest[open...]
                    return result
                }
                target = rest[rest.index(after: end)...]
            } else if afterClose < rest.endIndex, rest[afterClose] == "[" {
                guard let end = rest[rest.index(after: afterClose)...].firstIndex(of: "]") else {
                    result += rest[open...]
                    return result
                }
                target = rest[rest.index(after: end)...]
            } else {
                // A bare `[bracket]` in prose is text, not a link.
                result += rest[open...]
                return result
            }
            // An image's alt text is its visible words; without any, drop it.
            if result.hasSuffix("!") {
                result.removeLast()
            }
            result += label
            rest = target
        }
        result += rest
        return result
    }

    /// A table row as its cells, left to right.
    private static func tableRowText(_ line: String) -> String {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        let text = cells.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        return removingInlineMarkers(text)
    }

    /// Which lines belong to a table: the divider, the header above it, and the
    /// rows below it. Read first, so prose with a stray pipe stays prose.
    private static func tableLineIndexes(
        in lines: [String]
    ) -> (isDivider: Set<Int>, isContent: Set<Int>) {
        var dividers: Set<Int> = []
        var content: Set<Int> = []
        for index in lines.indices where isTableDivider(lines[index]) {
            dividers.insert(index)
            if index > 0 {
                content.insert(index - 1)
            }
            var next = index + 1
            while next < lines.count, isTableRow(lines[next]) {
                content.insert(next)
                next += 1
            }
        }
        return (dividers, content.subtracting(dividers))
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var sawDash = false
        var sawPipe = false
        for character in trimmed {
            switch character {
            case "-":
                sawDash = true
            case "|":
                sawPipe = true
            case ":", " ", "\t":
                continue
            default:
                return false
            }
        }
        return sawDash && sawPipe
    }

    /// One line per block, no blank lines between them: the folded card's three
    /// lines are the message, not Markdown's paragraph spacing.
    private static func joiningPreviewLines(_ lines: [String]) -> String {
        lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folded card shows three lines; keeping a few more keeps a narrow
    /// card's wrapped lines honest without carrying the whole message.
    private static func capping(_ text: String) -> (text: String, didCut: Bool) {
        var kept: [String] = []
        var characters = 0
        var didCut = false
        for line in text.components(separatedBy: "\n") {
            guard kept.count < previewLineCap else {
                didCut = true
                break
            }
            let remaining = previewCharacterCap - characters
            guard remaining > 0 else {
                didCut = true
                break
            }
            guard line.count <= remaining else {
                // A single long line is cut, never dropped: an empty preview
                // would hide the message it is standing in for.
                kept.append(String(line.prefix(remaining)))
                didCut = true
                break
            }
            kept.append(line)
            characters += line.count + 1
        }
        return (kept.joined(separator: "\n"), didCut)
    }
}
