import Foundation

/// Client-local URL used for Obsidian-style wiki links in workspace markdown.
///
/// The URL is never sent to the server. It gives UIKit's attributed-link
/// pipeline a scheme to carry a workspace-relative markdown target until the
/// tap handler converts it back into `FileLinkPayload` navigation.
enum WorkspaceWikiLinkURL {
    static let scheme = "oppi-workspace-note"

    static func make(workspaceID: String, filePath: String) -> URL? {
        let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty, !filePath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "workspaceId", value: workspaceID),
            URLQueryItem(name: "path", value: filePath),
        ]
        return components.url
    }

    static func parse(_ url: URL) -> (workspaceID: String, filePath: String)? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let workspaceID = components?.queryItems?.first(where: { $0.name == "workspaceId" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = components?.queryItems?.first(where: { $0.name == "path" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspaceID, !workspaceID.isEmpty,
              let filePath, !filePath.isEmpty else {
            return nil
        }
        return (workspaceID, filePath)
    }
}

/// Rewrites the supported wiki-link subset into normal markdown link inlines.
///
/// Supported syntax:
/// - `[[target]]`
/// - `[[target|label]]`
///
/// Targets resolve to workspace-relative file paths. If a target has no file
/// extension, `.md` is appended. Targets starting with `./` or `../` resolve
/// against the source markdown file's directory; all other targets are treated
/// as workspace-relative paths.
enum MarkdownWikiLinkRewriter {
    static func sourceForCommonMarkParsing(_ source: String) -> String {
        guard source.contains("[["), source.contains("|") else { return source }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var inFence = false
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let includesNewline = lineEnd < source.endIndex
            let line = String(source[lineStart ..< lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFenceLine(trimmed) {
                result += line
                inFence.toggle()
            } else if !inFence, !isIndentedCodeLine(line), needsWikiLinkPipeEscaping(in: line) {
                result += escapingWikiLinkPipes(in: line)
            } else {
                result += line
            }

            if includesNewline {
                result += "\n"
                lineStart = source.index(after: lineEnd)
            } else {
                lineStart = lineEnd
            }
        }

        return result
    }

    static func rewrite(
        blocks: [MarkdownBlock],
        workspaceID: String?,
        sourceDirectory: String?
    ) -> [MarkdownBlock] {
        blocks.map { rewrite(block: $0, workspaceID: workspaceID, sourceDirectory: sourceDirectory) }
    }

    static func resolvedWorkspacePath(target: String, sourceDirectory: String?) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        guard !path.contains("#"), !path.contains("?"), !path.contains(":") else { return nil }

        let resolveFromSource = path.hasPrefix("./") || path.hasPrefix("../")
        if resolveFromSource,
           let sourceDirectory,
           !sourceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = sourceDirectory + "/" + path
        }

        guard var normalized = normalizeWorkspacePath(path) else { return nil }
        if (normalized as NSString).pathExtension.isEmpty {
            normalized += ".md"
        }
        return normalized
    }

    private static func rewrite(
        block: MarkdownBlock,
        workspaceID: String?,
        sourceDirectory: String?
    ) -> MarkdownBlock {
        switch block {
        case .heading(let level, let inlines):
            return .heading(
                level: level,
                inlines: rewrite(inlines: inlines, workspaceID: workspaceID, sourceDirectory: sourceDirectory)
            )
        case .paragraph(let inlines):
            return .paragraph(rewrite(inlines: inlines, workspaceID: workspaceID, sourceDirectory: sourceDirectory))
        case .blockQuote(let children):
            return .blockQuote(rewrite(blocks: children, workspaceID: workspaceID, sourceDirectory: sourceDirectory))
        case .unorderedList(let items):
            return .unorderedList(items.map { rewrite(blocks: $0, workspaceID: workspaceID, sourceDirectory: sourceDirectory) })
        case .orderedList(let start, let items):
            return .orderedList(
                start: start,
                items.map { rewrite(blocks: $0, workspaceID: workspaceID, sourceDirectory: sourceDirectory) }
            )
        case .taskList(let items):
            return .taskList(items.map { item in
                MarkdownBlock.TaskItem(
                    checked: item.checked,
                    content: rewrite(blocks: item.content, workspaceID: workspaceID, sourceDirectory: sourceDirectory)
                )
            })
        case .table(let headers, let rows):
            return .table(
                headers: headers.map { rewrite(inlines: $0, workspaceID: workspaceID, sourceDirectory: sourceDirectory) },
                rows: rows.map { row in
                    row.map { rewrite(inlines: $0, workspaceID: workspaceID, sourceDirectory: sourceDirectory) }
                }
            )
        case .codeBlock, .thematicBreak, .htmlBlock:
            return block
        }
    }

    private static func rewrite(
        inlines: [MarkdownInline],
        workspaceID: String?,
        sourceDirectory: String?
    ) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        result.reserveCapacity(inlines.count)

        for inline in inlines {
            switch inline {
            case .text(let text):
                result.append(contentsOf: rewriteText(text, workspaceID: workspaceID, sourceDirectory: sourceDirectory))
            case .emphasis(let children):
                result.append(.emphasis(rewrite(inlines: children, workspaceID: workspaceID, sourceDirectory: sourceDirectory)))
            case .strong(let children):
                result.append(.strong(rewrite(inlines: children, workspaceID: workspaceID, sourceDirectory: sourceDirectory)))
            case .strikethrough(let children):
                result.append(.strikethrough(rewrite(inlines: children, workspaceID: workspaceID, sourceDirectory: sourceDirectory)))
            case .link, .code, .image, .softBreak, .hardBreak, .html:
                result.append(inline)
            }
        }

        return result
    }

    private static func rewriteText(
        _ text: String,
        workspaceID: String?,
        sourceDirectory: String?
    ) -> [MarkdownInline] {
        guard text.contains("[[") else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let open = text.range(of: "[[", range: cursor ..< text.endIndex) {
            if open.lowerBound > cursor {
                result.append(.text(String(text[cursor ..< open.lowerBound])))
            }

            let contentStart = open.upperBound
            guard let close = text.range(of: "]]", range: contentStart ..< text.endIndex) else {
                result.append(.text(String(text[open.lowerBound ..< text.endIndex])))
                return result
            }

            let rawContent = String(text[contentStart ..< close.lowerBound])
            if let rewritten = inline(forWikiLinkContent: rawContent, workspaceID: workspaceID, sourceDirectory: sourceDirectory) {
                result.append(rewritten)
            } else {
                result.append(.text(String(text[open.lowerBound ..< close.upperBound])))
            }
            cursor = close.upperBound
        }

        if cursor < text.endIndex {
            result.append(.text(String(text[cursor ..< text.endIndex])))
        }

        return result.isEmpty ? [.text(text)] : result
    }

    private static func inline(
        forWikiLinkContent rawContent: String,
        workspaceID: String?,
        sourceDirectory: String?
    ) -> MarkdownInline? {
        let normalizedContent = rawContent.replacingOccurrences(of: #"\|"#, with: "|")
        let pieces = normalizedContent.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawTarget = pieces.first else { return nil }

        let target = String(rawTarget).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let filePath = resolvedWorkspacePath(target: target, sourceDirectory: sourceDirectory) else {
            return nil
        }

        let rawLabel = pieces.count == 2 ? String(pieces[1]) : target
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? target : label

        guard let workspaceID,
              !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = WorkspaceWikiLinkURL.make(workspaceID: workspaceID, filePath: filePath) else {
            return .text(display)
        }

        return .link(children: [.text(display)], destination: url.absoluteString)
    }

    private static func needsWikiLinkPipeEscaping(in line: String) -> Bool {
        guard line.contains("[["), line.contains("|") else { return false }

        var cursor = line.startIndex
        var inCode = false
        var inWikiLink = false

        while cursor < line.endIndex {
            if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                inCode.toggle()
                cursor = line.index(after: cursor)
                continue
            }

            if !inCode, matches("[[", in: line, at: cursor) {
                inWikiLink = true
                cursor = line.index(cursor, offsetBy: 2)
                continue
            }

            if !inCode, inWikiLink, matches("]]", in: line, at: cursor) {
                inWikiLink = false
                cursor = line.index(cursor, offsetBy: 2)
                continue
            }

            if line[cursor] == "|", !inCode, !inWikiLink, !isEscaped(at: cursor, in: line) {
                return true
            }

            cursor = line.index(after: cursor)
        }

        return false
    }

    private static func escapingWikiLinkPipes(in line: String) -> String {
        var result = ""
        result.reserveCapacity(line.utf8.count)
        var cursor = line.startIndex

        while cursor < line.endIndex,
              let open = nextWikiLinkOpenOutsideCode(in: line, from: cursor) {
            let contentStart = line.index(open, offsetBy: 2)
            result.append(contentsOf: line[cursor ..< contentStart])
            guard let close = line.range(of: "]]", range: contentStart ..< line.endIndex) else {
                result.append(contentsOf: line[contentStart ..< line.endIndex])
                return result
            }

            var contentCursor = contentStart
            while contentCursor < close.lowerBound {
                let character = line[contentCursor]
                if character == "|", !isEscaped(at: contentCursor, in: line) {
                    result += #"\|"#
                } else {
                    result.append(character)
                }
                contentCursor = line.index(after: contentCursor)
            }

            result.append(contentsOf: "]]")
            cursor = close.upperBound
        }

        if cursor < line.endIndex {
            result.append(contentsOf: line[cursor ..< line.endIndex])
        }
        return result
    }

    private static func nextWikiLinkOpenOutsideCode(in line: String, from start: String.Index) -> String.Index? {
        var cursor = start
        var inCode = false

        while cursor < line.endIndex {
            if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                inCode.toggle()
                cursor = line.index(after: cursor)
                continue
            }
            if !inCode, matches("[[", in: line, at: cursor) {
                return cursor
            }
            cursor = line.index(after: cursor)
        }

        return nil
    }

    private static func matches(_ needle: String, in source: String, at index: String.Index) -> Bool {
        source[index...].hasPrefix(needle)
    }

    private static func isEscaped(at index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return false }
        var slashCount = 0
        var cursor = source.index(before: index)
        while source[cursor] == "\\" {
            slashCount += 1
            guard cursor > source.startIndex else { break }
            cursor = source.index(before: cursor)
        }
        return slashCount % 2 == 1
    }

    private static func isFenceLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func normalizeWorkspacePath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var output: [String] = []
        output.reserveCapacity(parts.count)

        for partSubsequence in parts {
            let part = String(partSubsequence).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                guard !output.isEmpty else { return nil }
                output.removeLast()
            } else {
                output.append(part)
            }
        }

        guard !output.isEmpty else { return nil }
        return output.joined(separator: "/")
    }
}
