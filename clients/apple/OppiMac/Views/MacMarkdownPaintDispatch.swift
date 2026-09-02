import Foundation

/// Mac paint kinds for assistant/user markdown. Parse stays in OppiCore;
/// this only classifies already-parsed `MarkdownBlock` / `MarkdownInline` nodes.
enum MacMarkdownPaintKind: Equatable, Sendable {
    case mermaidDiagram(code: String)
    case latexFormula(code: String)
    case codeListing(language: String?, code: String)
    case image(alt: String, source: String?, workspaceID: String?, sessionID: String?)
    case video(MarkdownVideoEmbed)
    case audio(MarkdownAudioEmbed)
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case html(source: String)
    case svg(source: String)
    case prose
}

/// Text versus promoted media inside one paragraph or heading.
enum MacMarkdownInlineRun: Equatable, Sendable {
    case text([MarkdownInline])
    case image(alt: String, source: String?, workspaceID: String?, sessionID: String?)
    case video(MarkdownVideoEmbed)
    case audio(MarkdownAudioEmbed)
    case latexFormula(String)
}

enum MacMarkdownPaintDispatch {
    /// Directory containing the markdown file. Explicit `sourceDirectory` wins;
    /// otherwise derived from `filePath` the same way iOS derives from `sourceFilePath`.
    /// e.g. `docs/notes.md` → `docs`, `notes.md` → nil.
    static func resolvedSourceDirectory(
        _ sourceDirectory: String?,
        filePath: String?
    ) -> String? {
        let explicit = sourceDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        guard let filePath else { return nil }
        let dir = (filePath as NSString).deletingLastPathComponent
        return dir.isEmpty || dir == "." ? nil : dir
    }

    /// Shared parse path for Mac timeline markdown: CommonMark, then wiki rewrite
    /// so `![[clip.mp4]]` becomes `MarkdownInline.videoEmbed`.
    static func parsedBlocks(
        from markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> [MarkdownBlock] {
        rewriteWiki(
            blocks: parseCommonMark(markdown),
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
    }

    /// Incremental parse for a growing message. Wiki rewrite still runs on the
    /// combined blocks so `workspaceID` / `sessionID` match `parsedBlocks`.
    static func parseStreaming(
        _ markdown: String,
        parser: inout CommonMarkStreamingParser,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> (blocks: [MarkdownBlock], strategy: CommonMarkStreamingParseStrategy) {
        let parsed = parser.parse(markdown)
        return (
            rewriteWiki(
                blocks: parsed.blocks,
                workspaceID: workspaceID,
                sessionID: sessionID,
                sourceDirectory: sourceDirectory
            ),
            parsed.strategy
        )
    }

    static func hasStructuredPaint(
        from markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> Bool {
        kinds(
            from: markdown,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        ).contains { kind in
            switch kind {
            case .mermaidDiagram, .codeListing, .image, .video, .audio, .latexFormula, .table, .html, .svg:
                return true
            case .prose:
                return false
            }
        }
    }

    private static func rewriteWiki(
        blocks: [MarkdownBlock],
        workspaceID: String?,
        sessionID: String?,
        sourceDirectory: String?
    ) -> [MarkdownBlock] {
        MarkdownWikiLinkRewriter.rewrite(
            blocks: blocks,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
    }

    static func kinds(
        from markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> [MacMarkdownPaintKind] {
        kinds(
            from: parsedBlocks(
                from: markdown,
                workspaceID: workspaceID,
                sessionID: sessionID,
                sourceDirectory: sourceDirectory
            ),
            workspaceID: workspaceID,
            sessionID: sessionID
        )
    }

    static func kinds(
        from blocks: [MarkdownBlock],
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) -> [MacMarkdownPaintKind] {
        blocks.flatMap { kinds(from: $0, workspaceID: workspaceID, sessionID: sessionID) }
    }

    static func kinds(
        from block: MarkdownBlock,
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) -> [MacMarkdownPaintKind] {
        switch block {
        case .codeBlock(let language, let code):
            return [codeBlockKind(language: language, code: code)]
        case .paragraph(let inlines):
            return paragraphKinds(inlines, workspaceID: workspaceID, sessionID: sessionID)
        case .heading(_, let inlines):
            return inlineMediaKinds(
                inlines,
                includeProse: true,
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        case .blockQuote(let children):
            return children.flatMap { kinds(from: $0, workspaceID: workspaceID, sessionID: sessionID) }
        case .unorderedList(let items), .orderedList(_, let items):
            return items.flatMap { item in
                item.flatMap { kinds(from: $0, workspaceID: workspaceID, sessionID: sessionID) }
            }
        case .taskList(let items):
            return items.flatMap { item in
                item.content.flatMap { kinds(from: $0, workspaceID: workspaceID, sessionID: sessionID) }
            }
        case .table(let headers, let rows):
            return [.table(headers: headers, rows: rows)]
        case .htmlBlock(let html):
            if MacMarkupPreviewKind.from(htmlBlock: html) == .svg {
                return [.svg(source: html)]
            }
            return [.html(source: html)]
        case .thematicBreak:
            return [.prose]
        }
    }

    /// `mermaid` / `mmd` → diagram; `latex` / `tex` / `math` → formula; else listing.
    static func codeBlockKind(language: String?, code: String) -> MacMarkdownPaintKind {
        guard let language, !language.isEmpty else {
            return .codeListing(language: language, code: code)
        }
        switch SyntaxLanguage.detect(language) {
        case .mermaid:
            return .mermaidDiagram(code: code)
        case .latex:
            return .latexFormula(code: code)
        default:
            return .codeListing(language: language, code: code)
        }
    }

    static func displayMathSource(from inlines: [MarkdownInline]) -> String? {
        let source = inlineSourcePreservingBreaks(inlines)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        if let inner = unwrapDisplayMathByDollars(source) {
            return inner
        }
        if let inner = unwrapDisplayMathByBrackets(source) {
            return inner
        }
        return nil
    }

    static func inlineRuns(
        from inlines: [MarkdownInline],
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) -> [MacMarkdownInlineRun] {
        var runs: [MacMarkdownInlineRun] = []
        var pending: [MarkdownInline] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            runs.append(.text(pending))
            pending.removeAll(keepingCapacity: true)
        }

        for inline in inlines {
            switch inline {
            case .image(let alt, let source):
                flushPending()
                runs.append(imageRun(alt: alt, source: source, workspaceID: workspaceID, sessionID: sessionID))
            case .videoEmbed(let embed):
                flushPending()
                runs.append(.video(embed))
            case .audioEmbed(let embed):
                flushPending()
                runs.append(.audio(embed))
            case .text(let string):
                let fragments = splitInlineMath(in: string)
                if fragments.count == 1, case .text(let piece) = fragments[0], piece == string {
                    pending.append(inline)
                } else {
                    for fragment in fragments {
                        switch fragment {
                        case .text(let piece):
                            if !piece.isEmpty {
                                pending.append(.text(piece))
                            }
                        case .latex(let code):
                            flushPending()
                            runs.append(.latexFormula(code))
                        }
                    }
                }
            default:
                pending.append(inline)
            }
        }
        flushPending()
        return runs
    }

    static func isSVGImageSource(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return false }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:image/svg+xml") {
            return true
        }
        let path = trimmed.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
        return (path as NSString).pathExtension.lowercased() == "svg"
    }

    static func isRelativeImageSource(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return false }
        if source.hasPrefix("data:") { return false }
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "file" || scheme == "data" {
                return false
            }
        }
        if source.hasPrefix("/") || source.hasPrefix("~") { return false }
        return true
    }

    /// Remote http(s) media must wait for an explicit load, matching iOS.
    static func isRemoteHTTPSource(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return false }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func paragraphKinds(
        _ inlines: [MarkdownInline],
        workspaceID: String?,
        sessionID: String?
    ) -> [MacMarkdownPaintKind] {
        if let formula = displayMathSource(from: inlines) {
            return [.latexFormula(code: formula)]
        }
        return inlineMediaKinds(
            inlines,
            includeProse: true,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
    }

    private static func inlineMediaKinds(
        _ inlines: [MarkdownInline],
        includeProse: Bool,
        workspaceID: String?,
        sessionID: String?
    ) -> [MacMarkdownPaintKind] {
        var kinds: [MacMarkdownPaintKind] = []
        var hasProse = false
        for run in inlineRuns(from: inlines, workspaceID: workspaceID, sessionID: sessionID) {
            switch run {
            case .text(let textInlines):
                if includeProse, inlineChunkHasVisibleText(textInlines) {
                    hasProse = true
                }
            case .image(let alt, let source, let imageWorkspaceID, let imageSessionID):
                kinds.append(
                    .image(
                        alt: alt,
                        source: source,
                        workspaceID: imageWorkspaceID,
                        sessionID: imageSessionID
                    )
                )
            case .video(let embed):
                kinds.append(.video(embed))
            case .audio(let embed):
                kinds.append(.audio(embed))
            case .latexFormula(let code):
                kinds.append(.latexFormula(code: code))
            }
        }
        if kinds.isEmpty {
            return [.prose]
        }
        if hasProse {
            return [.prose] + kinds
        }
        return kinds
    }

    private static func imageRun(
        alt: String,
        source: String?,
        workspaceID: String?,
        sessionID: String?
    ) -> MacMarkdownInlineRun {
        if isRelativeImageSource(source) {
            return .image(alt: alt, source: source, workspaceID: workspaceID, sessionID: sessionID)
        }
        return .image(alt: alt, source: source, workspaceID: nil, sessionID: nil)
    }

    private static func inlineChunkHasVisibleText(_ inlines: [MarkdownInline]) -> Bool {
        for inline in inlines {
            switch inline {
            case .text(let string), .html(let string), .code(let string):
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children),
                 .link(let children, _):
                if inlineChunkHasVisibleText(children) {
                    return true
                }
            case .image, .videoEmbed, .audioEmbed, .softBreak, .hardBreak:
                continue
            }
        }
        return false
    }

    private static func inlineSourcePreservingBreaks(_ inlines: [MarkdownInline]) -> String {
        var result = ""
        result.reserveCapacity(128)
        for inline in inlines {
            switch inline {
            case .text(let string):
                result.append(string)
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children):
                result.append(inlineSourcePreservingBreaks(children))
            case .code(let code):
                result.append(code)
            case .link(let children, _):
                result.append(inlineSourcePreservingBreaks(children))
            case .image(let alt, _):
                result.append(alt)
            case .videoEmbed(let embed):
                result.append(embed.displayLabel)
            case .audioEmbed(let embed):
                result.append(embed.displayLabel)
            case .softBreak, .hardBreak:
                result.append("\n")
            case .html(let raw):
                result.append(raw)
            }
        }
        return result
    }

    private static func unwrapDisplayMathByDollars(_ source: String) -> String? {
        guard let inner = stripWrapping(source, open: "$$", close: "$$") else { return nil }
        guard isLikelyDisplayLatexMath(inner) else { return nil }
        return inner
    }

    private static func unwrapDisplayMathByBrackets(_ source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let lastNonEmpty = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              firstNonEmpty < lastNonEmpty else {
            return nil
        }

        let opening = String(lines[firstNonEmpty]).trimmingCharacters(in: .whitespaces)
        let closing = String(lines[lastNonEmpty]).trimmingCharacters(in: .whitespaces)
        guard opening == "\\[", closing == "\\]" else {
            return nil
        }

        let inner = lines[(firstNonEmpty + 1) ..< lastNonEmpty]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyDisplayLatexMath(inner) else { return nil }
        return inner
    }

    private static func stripWrapping(_ source: String, open: String, close: String) -> String? {
        guard source.hasPrefix(open), source.hasSuffix(close) else { return nil }
        let start = source.index(source.startIndex, offsetBy: open.count)
        let end = source.index(source.endIndex, offsetBy: -close.count)
        guard start <= end else { return nil }
        let inner = source[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func isLikelyDisplayLatexMath(_ source: String) -> Bool {
        TeXMathParser().parseValidated(source).isRenderable
    }

    private enum InlineMathFragment: Equatable {
        case text(String)
        case latex(String)
    }

    private static func splitInlineMath(in source: String) -> [InlineMathFragment] {
        var fragments: [InlineMathFragment] = []
        var plain = ""
        var cursor = source.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            fragments.append(.text(plain))
            plain.removeAll(keepingCapacity: true)
        }

        while cursor < source.endIndex {
            if source[cursor...].hasPrefix(#"\\("#) {
                plain += #"\("#
                cursor = source.index(cursor, offsetBy: 3)
                continue
            }
            if source[cursor...].hasPrefix(#"\\)"#) {
                plain += #"\)"#
                cursor = source.index(cursor, offsetBy: 3)
                continue
            }
            if source[cursor...].hasPrefix(#"\$"#), isEscapedDollar(at: source.index(after: cursor), in: source) {
                plain.append("$")
                cursor = source.index(cursor, offsetBy: 2)
                continue
            }
            if source[cursor...].hasPrefix(#"\("#),
               let closeRange = source.range(
                   of: #"\)"#,
                   range: source.index(cursor, offsetBy: 2) ..< source.endIndex
               ) {
                let latexStart = source.index(cursor, offsetBy: 2)
                let latex = String(source[latexStart ..< closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !latex.isEmpty, isLikelyInlineLatexMath(latex) {
                    flushPlain()
                    fragments.append(.latex(latex))
                    cursor = closeRange.upperBound
                    continue
                }
            }
            if source[cursor] == "$",
               !isEscapedDollar(at: cursor, in: source),
               !isDisplayMathDollar(at: cursor, in: source) {
                let latexStart = source.index(after: cursor)
                if let close = nextInlineMathDelimiter(in: source, from: latexStart) {
                    let latex = String(source[latexStart ..< close])
                    if isLikelyInlineLatexMath(latex) {
                        flushPlain()
                        fragments.append(.latex(latex))
                        cursor = source.index(after: close)
                        continue
                    }
                }
            }
            plain.append(source[cursor])
            cursor = source.index(after: cursor)
        }

        flushPlain()
        return fragments
    }

    private static func nextInlineMathDelimiter(in source: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < source.endIndex {
            if source[index] == "$",
               !isEscapedDollar(at: index, in: source),
               !isDisplayMathDollar(at: index, in: source) {
                return index
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func isEscapedDollar(at index: String.Index, in source: String) -> Bool {
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

    private static func isDisplayMathDollar(at index: String.Index, in source: String) -> Bool {
        let previousIsDollar = index > source.startIndex && source[source.index(before: index)] == "$"
        let nextIsDollar = source.index(after: index) < source.endIndex && source[source.index(after: index)] == "$"
        return previousIsDollar || nextIsDollar
    }

    private static func isLikelyInlineLatexMath(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == source, hasBalancedLatexBraces(trimmed) else { return false }
        if trimmed.contains("\\") || trimmed.contains("^") || trimmed.contains("_")
            || (trimmed.contains("{") && trimmed.contains("}")) {
            return true
        }
        if trimmed.contains(where: { "=+-*/<>".contains($0) })
            && trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
            return true
        }
        if trimmed.allSatisfy({ $0.isNumber || ".,".contains($0) }) {
            return false
        }
        return trimmed.first?.isLetter == true
    }

    private static func hasBalancedLatexBraces(_ source: String) -> Bool {
        var depth = 0
        for index in source.indices {
            var slashCount = 0
            var cursor = index
            while cursor > source.startIndex {
                let previous = source.index(before: cursor)
                guard source[previous] == "\\" else { break }
                slashCount += 1
                cursor = previous
            }
            guard slashCount % 2 == 0 else { continue }
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}
