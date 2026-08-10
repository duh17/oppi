import SwiftUI

// MARK: - Global Segment Cache

/// Process-wide cache for parsed markdown segments.
///
/// Keyed by a stable content hash so scroll-back can hit instantly.
/// Bounded by both entry count and total source text bytes to avoid
/// retaining large markdown histories across session switches.
final class MarkdownSegmentCache: @unchecked Sendable {
    // SAFETY (`@unchecked Sendable`):
    // - Every mutable field (`entries`, `counter`, `totalSourceBytes`) is read/written only under `lock`.
    // - Stored values are value-semantic (`[FlatSegment]`, `Int`, `UInt64`) and never expose shared mutable references.
    // - Public APIs return copied value data and do not execute callbacks while the lock is held.
    // - This process-wide singleton intentionally allows cross-thread access, with synchronization fully handled by `NSLock`.
    static let shared = MarkdownSegmentCache()

    private struct Entry {
        let segments: [FlatSegment]
        var order: UInt64
        let sourceBytes: Int
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var counter: UInt64 = 0
    private var totalSourceBytes = 0

    /// Hard cap on number of cached markdown messages.
    /// Sized to hold a full session's worth of assistant messages (~128 items,
    /// ~50% are assistant messages with markdown).
    private let maxEntries = 128
    /// Hard cap on total source text bytes retained in cache.
    private let maxTotalSourceBytes = 1024 * 1024
    /// Skip caching very large messages (still rendered on-demand).
    private let maxEntrySourceBytes = 16 * 1024

    func shouldCache(_ content: String) -> Bool {
        content.utf8.count <= maxEntrySourceBytes
    }

    func get(
        _ content: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil
    ) -> [FlatSegment]? {
        guard shouldCache(content) else { return nil }
        let key = stableKey(
            for: content,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        counter += 1
        entry.order = counter
        entries[key] = entry
        return entry.segments
    }

    func set(
        _ content: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        segments: [FlatSegment]
    ) {
        let sourceBytes = content.utf8.count
        guard sourceBytes <= maxEntrySourceBytes else { return }

        let key = stableKey(
            for: content,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )
        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[key] {
            totalSourceBytes -= existing.sourceBytes
        }

        counter += 1
        entries[key] = Entry(segments: segments, order: counter, sourceBytes: sourceBytes)
        totalSourceBytes += sourceBytes
        evictIfNeeded()
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        totalSourceBytes = 0
    }

    func snapshot() -> (entries: Int, totalSourceBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries: entries.count, totalSourceBytes: totalSourceBytes)
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries || totalSourceBytes > maxTotalSourceBytes else { return }

        let sorted = entries.sorted { $0.value.order < $1.value.order }
        for (key, entry) in sorted {
            guard entries.count > maxEntries || totalSourceBytes > maxTotalSourceBytes else { break }
            entries.removeValue(forKey: key)
            totalSourceBytes -= entry.sourceBytes
        }
    }

    private func stableKey(
        for content: String,
        themeID: ThemeID,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil
    ) -> UInt64 {
        // FNV-1a 64-bit hash (stable across process launches).
        var hash: UInt64 = 14_695_981_039_346_656_037

        func mix(_ string: String?, separator: UInt64) {
            hash ^= separator
            hash &*= 1_099_511_628_211
            for byte in (string ?? "").utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        mix(themeID.rawValue, separator: 0xFF)
        mix(serverID, separator: 0xFE)
        mix(workspaceID, separator: 0xFD)
        mix(sessionID, separator: 0xFC)
        mix(serverBaseURL?.absoluteString, separator: 0xFB)
        mix(sourceDirectory, separator: 0xFA)
        mix(content, separator: 0xF9)
        return hash
    }
}

// MARK: - Shared Workspace File URL Helpers

enum WorkspaceFileURL {
    /// Build `{base}/workspaces/{workspaceID}/raw/{path}`.
    static func make(baseURL: URL, workspaceID: String, filePath: String) -> URL? {
        guard !workspaceID.isEmpty else { return nil }
        let normalizedPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
        guard !normalizedPath.isEmpty else { return nil }

        return baseURL
            .appendingPathComponent("workspaces")
            .appendingPathComponent(workspaceID)
            .appendingPathComponent("raw")
            .appendingPathComponent(normalizedPath)
    }

    /// Parse `{base}/workspaces/{workspaceID}/raw/{path}`.
    /// Also accepts legacy `/files/` URLs from older transcript renders.
    static func parse(_ url: URL) -> (workspaceID: String, filePath: String)? {
        let components = url.pathComponents

        guard let workspaceIndex = components.firstIndex(of: "workspaces"),
              components.count > workspaceIndex + 1 else {
            return nil
        }

        let workspaceID = components[workspaceIndex + 1]
        guard !workspaceID.isEmpty else { return nil }

        let routeSearchStart = workspaceIndex + 2
        guard routeSearchStart < components.count,
              let routeIndex = components[routeSearchStart..<components.count].firstIndex(where: { $0 == "raw" || $0 == "files" }),
              components.count > routeIndex + 1 else {
            return nil
        }

        let filePath = components[(routeIndex + 1)...].joined(separator: "/")
        guard !filePath.isEmpty else { return nil }

        return (workspaceID: workspaceID, filePath: filePath)
    }
}

enum SessionFileURL {
    private static let scheme = "oppi-session-file"

    /// Build a client-local URL that encodes a session-scoped file fetch.
    static func make(workspaceID: String, sessionID: String, filePath: String) -> URL? {
        guard !workspaceID.isEmpty, !sessionID.isEmpty, !filePath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "session-file"
        components.path = "/\(workspaceID)/\(sessionID)"
        components.queryItems = [
            URLQueryItem(name: "path", value: filePath),
        ]
        return components.url
    }

    /// Parse a client-local `oppi-session-file://...` URL.
    static func parse(_ url: URL) -> (workspaceID: String, sessionID: String, filePath: String)? {
        guard url.scheme == scheme else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let workspaceID = components[0]
        let sessionID = components[1]
        guard !workspaceID.isEmpty, !sessionID.isEmpty,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filePath = query.queryItems?.first(where: { $0.name == "path" })?.value,
              !filePath.isEmpty else {
            return nil
        }
        return (workspaceID: workspaceID, sessionID: sessionID, filePath: filePath)
    }
}

/// Segment types for the flat renderer.
///
/// Built once from `[MarkdownBlock]` via `build(from:)`, then cached in `@State`.
/// All AttributedString construction happens at build time,
/// so consumers can render with a simple switch over pre-computed values.
enum FlatSegment: Sendable {
    case text(AttributedString)
    case codeBlock(language: String?, code: String)
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case thematicBreak
    /// A standalone image paragraph. The URL is fully resolved at build time
    /// using the workspace context. Rendered by `NativeMarkdownImageView`.
    case image(alt: String, url: URL)
    /// A mermaid diagram code block. The applier decides whether to render
    /// the diagram or show as a code block based on streaming state.
    case mermaidDiagram(code: String)
    /// A LaTeX math code block. Rendered as a formula when the fence is
    /// closed, or as a syntax-highlighted code block while streaming.
    case latexBlock(code: String)

    /// Convert CommonMark blocks into renderable segments.
    ///
    /// Adjacent text-like blocks are merged into a single `.text` segment so
    /// native selection can cross paragraph/list/heading boundaries.
    /// Code blocks and tables remain standalone segments.
    ///
    /// When image links resolve to remote, workspace-relative, or session file
    /// URLs, paragraph image inlines are promoted to `.image` segments instead
    /// of the alt-text fallback. Direct remote URL fetching is still gated by
    /// `NativeMarkdownImageView`.
    /// Cached paragraph separator. Created once to avoid repeated allocation.
    private static let paragraphSeparator = AttributedString("\n\n")

    struct BuildResult: Sendable {
        let segments: [FlatSegment]
        let sourceLineRanges: [ClosedRange<Int>?]
    }

    static func build(
        from blocks: [MarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        /// Directory path of the source markdown file (e.g. "docs/").
        /// Used to resolve relative image paths like `images/foo.png`
        /// → `docs/images/foo.png` in the workspace.
        sourceDirectory: String? = nil,
        /// Timeline markdown merges adjacent text-like blocks so native text
        /// selection can cross paragraphs. Full-screen readers can disable
        /// merging and virtualize at paragraph/list granularity while using the
        /// same parser and render views.
        mergeAdjacentTextSegments: Bool = true
    ) -> [Self] {
        buildResult(
            from: blocks,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            mergeAdjacentTextSegments: mergeAdjacentTextSegments
        ).segments
    }

    static func buildWithSourceLineRanges(
        from blocks: [LocatedMarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        mergeAdjacentTextSegments: Bool = true
    ) -> BuildResult {
        buildResult(
            from: blocks.map(\.block),
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            sourceLineRanges: blocks.map(\.lineRange),
            mergeAdjacentTextSegments: mergeAdjacentTextSegments
        )
    }

    private static func buildResult(
        from blocks: [MarkdownBlock],
        themeID: ThemeID,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String?,
        sourceLineRanges: [ClosedRange<Int>?]? = nil,
        mergeAdjacentTextSegments: Bool
    ) -> BuildResult {
        let palette = themeID.palette
        let blocks = MarkdownWikiLinkRewriter.rewrite(
            blocks: blocks,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
        var result: [Self] = []
        result.reserveCapacity(blocks.count)
        var resultLineRanges: [ClosedRange<Int>?] = []
        resultLineRanges.reserveCapacity(blocks.count)

        var pendingText = AttributedString()
        var pendingTextLineRange: ClosedRange<Int>?
        var hasPendingText = false

        func mergedLineRange(_ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?) -> ClosedRange<Int>? {
            switch (lhs, rhs) {
            case (nil, nil):
                return nil
            case (let range?, nil), (nil, let range?):
                return range
            case (let lhs?, let rhs?):
                return min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
            }
        }

        func sourceLineRange(at index: Int) -> ClosedRange<Int>? {
            guard let sourceLineRanges, sourceLineRanges.indices.contains(index) else { return nil }
            return sourceLineRanges[index]
        }

        func appendSegment(_ segment: Self, lineRange: ClosedRange<Int>?) {
            result.append(segment)
            resultLineRanges.append(lineRange)
        }

        func flushPendingText() {
            guard hasPendingText, !pendingText.characters.isEmpty else { return }
            appendSegment(.text(pendingText), lineRange: pendingTextLineRange)
            pendingText = AttributedString()
            pendingTextLineRange = nil
            hasPendingText = false
        }

        func appendTextBlock(_ attributed: AttributedString, lineRange: ClosedRange<Int>?) {
            guard !attributed.characters.isEmpty else { return }
            guard mergeAdjacentTextSegments else {
                flushPendingText()
                appendSegment(.text(attributed), lineRange: lineRange)
                return
            }
            if hasPendingText {
                pendingText.append(paragraphSeparator)
            }
            pendingText.append(attributed)
            pendingTextLineRange = mergedLineRange(pendingTextLineRange, lineRange)
            hasPendingText = true
        }

        func appendCodeSegment(language: String?, code: String, lineRange: ClosedRange<Int>?) {
            if let lang = language, SyntaxLanguage.detect(lang) == .mermaid {
                appendSegment(.mermaidDiagram(code: code), lineRange: lineRange)
            } else if let lang = language, SyntaxLanguage.detect(lang) == .latex {
                appendSegment(.latexBlock(code: code), lineRange: lineRange)
            } else {
                appendSegment(.codeBlock(language: language, code: code), lineRange: lineRange)
            }
        }

        // Render list item text as attributed lines, but keep nested block-level
        // nodes (fenced code, tables, thematic breaks) as standalone segments.
        // This preserves code fences inside list items instead of dropping them.
        func appendListBlock(
            items: [[MarkdownBlock]],
            lineRange: ClosedRange<Int>?,
            markerForItem: (Int) -> AttributedString,
            continuationForItem: (Int) -> AttributedString,
            transformItemContent: (inout AttributedString, Int) -> Void = { _, _ in }
        ) {
            var textLines: [AttributedString] = []
            textLines.reserveCapacity(items.count)

            func flushListTextLines() {
                guard !textLines.isEmpty else { return }
                var merged = AttributedString()
                for (lineIndex, line) in textLines.enumerated() {
                    if lineIndex > 0 {
                        merged.append(AttributedString("\n"))
                    }
                    merged.append(line)
                }
                appendTextBlock(merged, lineRange: lineRange)
                textLines.removeAll(keepingCapacity: true)
            }

            for (itemIndex, itemBlocks) in items.enumerated() {
                var itemHasPrefix = false
                var emittedAnyRenderable = false

                func appendItemText(_ content: AttributedString) {
                    guard !content.characters.isEmpty else { return }
                    var rendered = content
                    transformItemContent(&rendered, itemIndex)
                    guard !rendered.characters.isEmpty else { return }

                    let prefix = itemHasPrefix ? continuationForItem(itemIndex) : markerForItem(itemIndex)
                    let continuation = continuationForItem(itemIndex)
                    var line = prefix
                    line.append(Self.prefixLines(afterFirstIn: rendered, with: continuation))
                    textLines.append(line)
                    itemHasPrefix = true
                    emittedAnyRenderable = true
                }

                for itemBlock in itemBlocks {
                    switch itemBlock {
                    case .codeBlock(let language, let code):
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendCodeSegment(language: language, code: code, lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .table(let headers, let rows):
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendSegment(.table(headers: headers, rows: rows), lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .thematicBreak:
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendSegment(.thematicBreak, lineRange: lineRange)
                        emittedAnyRenderable = true

                    default:
                        appendItemText(Self.attributedString(for: itemBlock, palette: palette))
                    }
                }

                if !emittedAnyRenderable, !itemHasPrefix {
                    textLines.append(markerForItem(itemIndex))
                }
            }

            flushListTextLines()
        }

        for (blockIndex, block) in blocks.enumerated() {
            let lineRange = sourceLineRange(at: blockIndex)

            switch block {
            case .codeBlock(let language, let code):
                flushPendingText()
                appendCodeSegment(language: language, code: code, lineRange: lineRange)

            case .table(let headers, let rows):
                flushPendingText()
                appendSegment(.table(headers: headers, rows: rows), lineRange: lineRange)

            case .thematicBreak:
                flushPendingText()
                appendSegment(.thematicBreak, lineRange: lineRange)

            case .paragraph(let inlines):
                // Promote standalone display-math paragraphs to `.latexBlock`
                // so assistant responses using `\[ ... \]` or `$$ ... $$`
                // render as formulas in the timeline.
                // Promote image-only paragraphs to a standalone `.image` segment
                // when the source is a resolvable URL (absolute or workspace-relative).
                if let latexSource = resolveStandaloneLatex(inlines: inlines) {
                    flushPendingText()
                    appendSegment(.latexBlock(code: latexSource), lineRange: lineRange)
                } else if let imageSegments = resolveParagraphImageSegments(
                    inlines: inlines,
                    palette: palette,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL,
                    sourceDirectory: sourceDirectory
                ) {
                    for segment in imageSegments {
                        switch segment {
                        case .text(let attributed):
                            appendTextBlock(attributed, lineRange: lineRange)
                        case .image(let alt, let url):
                            flushPendingText()
                            appendSegment(.image(alt: alt, url: url), lineRange: lineRange)
                        case .codeBlock, .table, .thematicBreak, .mermaidDiagram, .latexBlock:
                            break
                        }
                    }
                } else {
                    let attributed = Self.attributedString(for: block, palette: palette)
                    appendTextBlock(attributed, lineRange: lineRange)
                }

            case .unorderedList(let items):
                appendListBlock(
                    items: items,
                    lineRange: lineRange,
                    markerForItem: { _ in
                        var marker = AttributedString("  • ")
                        marker.uiKit.foregroundColor = UIColor(palette.mdListBullet)
                        return marker
                    },
                    continuationForItem: { _ in AttributedString("    ") }
                )

            case .orderedList(let start, let items):
                let listFont = Self.listBodyFont()
                appendListBlock(
                    items: items,
                    lineRange: lineRange,
                    markerForItem: { itemIndex in
                        let markerText = "  \(start + itemIndex). "
                        var marker = AttributedString(markerText)
                        marker.uiKit.foregroundColor = UIColor(palette.mdListBullet)
                        marker.uiKit.font = listFont
                        return marker
                    },
                    continuationForItem: { itemIndex in
                        let markerText = "  \(start + itemIndex). "
                        var continuation = AttributedString(String(repeating: " ", count: markerText.count))
                        continuation.uiKit.font = listFont
                        return continuation
                    },
                    transformItemContent: { content, _ in
                        Self.applyListFont(to: &content, listFont: listFont)
                    }
                )

            default:
                let attributed = Self.attributedString(for: block, palette: palette)
                appendTextBlock(attributed, lineRange: lineRange)
            }
        }

        flushPendingText()
        return BuildResult(segments: result, sourceLineRanges: resultLineRanges)
    }

    private static func prefixLines(
        afterFirstIn attributed: AttributedString,
        with prefix: AttributedString
    ) -> AttributedString {
        guard !prefix.characters.isEmpty, attributed.characters.contains("\n") else { return attributed }

        var result = AttributedString()
        var segmentStart = attributed.startIndex
        var cursor = attributed.startIndex

        while cursor < attributed.endIndex {
            let character = attributed.characters[cursor]
            let next = attributed.characters.index(after: cursor)
            if character == "\n" {
                result.append(AttributedString(attributed[segmentStart ..< next]))
                if next < attributed.endIndex {
                    result.append(prefix)
                }
                segmentStart = next
            }
            cursor = next
        }

        if segmentStart < attributed.endIndex {
            result.append(AttributedString(attributed[segmentStart ..< attributed.endIndex]))
        }
        return result
    }

    // MARK: - Display Math Paragraph Detection

    /// Detect standalone display-math paragraphs and extract the inner TeX.
    ///
    /// Supported wrappers:
    /// - `$$ ... $$`
    /// - `\[ ... \]` (after CommonMark parsing this often appears as `[ ... ]`)
    ///
    /// We intentionally require the inner content to look math-like to avoid
    /// treating plain bracketed prose as LaTeX.
    private static func resolveStandaloneLatex(inlines: [MarkdownInline]) -> String? {
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

    /// Flatten inline nodes to plain text while preserving line breaks.
    ///
    /// Used only for structural detection (not display), so formatting marks
    /// are collapsed to their text content.
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
        // Multiline display math commonly arrives as:
        // [
        //   \\frac{...}{...}
        // ]
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

    private static func isLikelyLatexMath(_ source: String) -> Bool {
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

    // MARK: - Inline Math Rendering

    private struct InlineLatexRender {
        var attributed = AttributedString()
        var handledDelimiter = false
    }

    /// Render formulas as baseline-aligned text attachments while preserving
    /// the surrounding CommonMark runs. The previous plain-text conversion
    /// flattened the whole paragraph, dropping links, code styling, emphasis,
    /// and the mathematical layout users expected from LaTeX.
    private static func renderInlineLatexParagraph(
        _ inlines: [MarkdownInline],
        palette: ThemePalette,
        bodyColor: UIColor,
        bodyFont: UIFont
    ) -> AttributedString? {
        let render = renderInlineLatexInlines(
            inlines,
            palette: palette,
            bodyColor: bodyColor,
            bodyFont: bodyFont
        )
        return render.handledDelimiter ? render.attributed : nil
    }

    private static func renderInlineLatexInlines(
        _ inlines: [MarkdownInline],
        palette: ThemePalette,
        bodyColor: UIColor,
        bodyFont: UIFont
    ) -> InlineLatexRender {
        var result = InlineLatexRender()

        for inline in inlines {
            switch inline {
            case .text(let source):
                let rendered = renderInlineLatexText(
                    source,
                    palette: palette,
                    bodyColor: bodyColor,
                    bodyFont: bodyFont
                )
                result.attributed.append(rendered.attributed)
                result.handledDelimiter = result.handledDelimiter || rendered.handledDelimiter

            case .emphasis(let children):
                var rendered = renderInlineLatexInlines(
                    children,
                    palette: palette,
                    bodyColor: bodyColor,
                    bodyFont: bodyFont
                )
                rendered.attributed.inlinePresentationIntent = .emphasized
                result.attributed.append(rendered.attributed)
                result.handledDelimiter = result.handledDelimiter || rendered.handledDelimiter

            case .strong(let children):
                var rendered = renderInlineLatexInlines(
                    children,
                    palette: palette,
                    bodyColor: bodyColor,
                    bodyFont: bodyFont
                )
                rendered.attributed.inlinePresentationIntent = .stronglyEmphasized
                result.attributed.append(rendered.attributed)
                result.handledDelimiter = result.handledDelimiter || rendered.handledDelimiter

            case .code(let code):
                var rendered = AttributedString(code)
                rendered.uiKit.font = monospacedFont(forTextStyle: .subheadline)
                rendered.uiKit.foregroundColor = UIColor(palette.mdCode)
                rendered.uiKit.backgroundColor = UIColor(palette.bgHighlight)
                result.attributed.append(rendered)

            case .link(let children, let destination):
                var rendered = renderInlineLatexInlines(
                    children,
                    palette: palette,
                    bodyColor: bodyColor,
                    bodyFont: bodyFont
                )
                rendered.attributed.uiKit.foregroundColor = UIColor(palette.mdLink)
                rendered.attributed.underlineStyle = .single
                if let destination,
                   let url = URL(string: destination),
                   url.scheme != nil {
                    rendered.attributed.link = url
                }
                result.attributed.append(rendered.attributed)
                result.handledDelimiter = result.handledDelimiter || rendered.handledDelimiter

            case .image(let alt, _):
                var rendered = AttributedString(imageFallbackText(alt: alt))
                rendered.uiKit.font = bodyFont
                rendered.uiKit.foregroundColor = UIColor(palette.comment)
                result.attributed.append(rendered)

            case .softBreak, .hardBreak:
                var rendered = AttributedString("\n")
                rendered.uiKit.font = bodyFont
                rendered.uiKit.foregroundColor = bodyColor
                result.attributed.append(rendered)

            case .html(let raw):
                var rendered = AttributedString(raw)
                rendered.uiKit.font = bodyFont
                rendered.uiKit.foregroundColor = UIColor(palette.comment)
                result.attributed.append(rendered)

            case .strikethrough(let children):
                var rendered = renderInlineLatexInlines(
                    children,
                    palette: palette,
                    bodyColor: bodyColor,
                    bodyFont: bodyFont
                )
                rendered.attributed.strikethroughStyle = .single
                result.attributed.append(rendered.attributed)
                result.handledDelimiter = result.handledDelimiter || rendered.handledDelimiter
            }
        }

        return result
    }

    private static func renderInlineLatexText(
        _ source: String,
        palette: ThemePalette,
        bodyColor: UIColor,
        bodyFont: UIFont
    ) -> InlineLatexRender {
        var result = InlineLatexRender()
        var plain = ""
        var cursor = source.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            var attributed = AttributedString(plain)
            attributed.uiKit.font = bodyFont
            attributed.uiKit.foregroundColor = bodyColor
            result.attributed.append(attributed)
            plain.removeAll(keepingCapacity: true)
        }

        while cursor < source.endIndex {
            if source[cursor...].hasPrefix(#"\\("#) {
                plain += #"\("#
                cursor = source.index(cursor, offsetBy: 3)
                result.handledDelimiter = true
                continue
            }

            if source[cursor...].hasPrefix(#"\\)"#) {
                plain += #"\)"#
                cursor = source.index(cursor, offsetBy: 3)
                result.handledDelimiter = true
                continue
            }

            if source[cursor...].hasPrefix(#"\$"#), isEscapedDollar(at: source.index(after: cursor), in: source) {
                plain.append("$")
                cursor = source.index(cursor, offsetBy: 2)
                result.handledDelimiter = true
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
                if !latex.isEmpty,
                   let attachment = inlineLatexAttachment(
                       source: latex,
                       palette: palette,
                       bodyFont: bodyFont
                   ) {
                    flushPlain()
                    result.attributed.append(attachment)
                    result.handledDelimiter = true
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
                    if isLikelyLatexMath(latex),
                       let attachment = inlineLatexAttachment(
                           source: latex,
                           palette: palette,
                           bodyFont: bodyFont
                       ) {
                        flushPlain()
                        result.attributed.append(attachment)
                        result.handledDelimiter = true
                        cursor = source.index(after: close)
                        continue
                    }
                }
            }

            plain.append(source[cursor])
            cursor = source.index(after: cursor)
        }

        flushPlain()
        return result
    }

    private static func inlineLatexAttachment(
        source: String,
        palette: ThemePalette,
        bodyFont: UIFont
    ) -> AttributedString? {
        guard hasBalancedLatexBraces(source),
              let rendered = DocumentRenderPipeline.renderInlineLatexImage(
            text: source,
            config: RenderConfiguration(
                fontSize: bodyFont.pointSize,
                maxWidth: 1_000,
                theme: palette.renderTheme,
                displayMode: .inline
            )
        ) else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = CGRect(
            x: 0,
            y: -(rendered.size.height - rendered.baseline),
            width: rendered.size.width,
            height: rendered.size.height
        )
        attachment.accessibilityLabel = formulaAccessibilityLabel(for: source)
        return AttributedString(NSAttributedString(attachment: attachment))
    }

    private static func renderBareInlineLatexText(_ inlines: [MarkdownInline]) -> String? {
        guard inlines.count == 1, case .text(let source) = inlines[0] else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("$"), trimmed.hasPrefix("\\text{") else { return nil }
        let rendered = renderInlineLatexPlainText(trimmed)
        return rendered.isEmpty ? nil : rendered
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

    static func formulaAccessibilityLabel(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TeXMathParser().parseValidated(trimmed)
        let plain = parsed.isRenderable && !containsLossyAccessibilityNode(in: parsed.nodes)
            ? mathPlainText(from: parsed.nodes)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let accessibleValue = plain.isEmpty ? trimmed : plain
        if plain.isEmpty {
            return String(
                format: String(localized: "Math formula source: %@"),
                accessibleValue
            )
        }
        return String(format: String(localized: "Math formula: %@"), accessibleValue)
    }

    private static func renderInlineLatexPlainText(_ source: String) -> String {
        let parsed = TeXMathParser().parse(source.trimmingCharacters(in: .whitespacesAndNewlines))
        return mathPlainText(from: parsed)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mathPlainText(from nodes: [MathNode]) -> String {
        var output = ""
        for node in nodes {
            appendMathPlainText(node, to: &output)
        }
        return output
    }

    private static func appendMathPlainText(_ node: MathNode, to output: inout String) {
        switch node {
        case .number(let value), .variable(let value), .text(let value):
            appendMathToken(value, to: &output)
        case .operator(let op):
            appendMathOperator(op, to: &output)
        case .symbol(let symbol):
            appendMathToken(mathSymbolText(symbol), to: &output)
        case .fraction(let numerator, let denominator):
            appendMathToken(groupedFractionOperand(numerator), to: &output)
            appendMathToken("/", to: &output)
            appendMathToken(groupedFractionOperand(denominator), to: &output)
        case .superscript(let base, let exponent):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(exponent), to: &output)
        case .subscript(let base, let index):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(index), to: &output)
        case .subSuperscript(let base, let sub, let sup):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(sub), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(sup), to: &output)
        case .sqrt(let index, let radicand):
            appendMathToken("√", to: &output)
            if let index {
                appendMathToken("[", to: &output)
                appendMathToken(mathPlainText(from: index), to: &output)
                appendMathToken("]", to: &output)
            }
            appendMathToken("(", to: &output)
            appendMathToken(mathPlainText(from: radicand), to: &output)
            appendMathToken(")", to: &output)
        case .group(let body), .font(_, let body), .accent(_, let body):
            appendMathToken(mathPlainText(from: body), to: &output)
        case .leftRight(let left, let right, let body):
            appendMathToken(delimiterText(left), to: &output)
            appendMathToken(mathPlainText(from: body), to: &output)
            appendMathToken(delimiterText(right), to: &output)
        case .matrix(let rows, _), .environment(_, let rows):
            let rowText = rows.map { row in
                row.map { mathPlainText(from: $0) }.joined(separator: " | ")
            }.joined(separator: "; ")
            appendMathToken(rowText, to: &output)
        case .space:
            appendSpace(to: &output)
        case .bigOperator(let kind, let limits):
            appendMathToken(bigOperatorText(kind), to: &output)
            if let lower = limits?.lower {
                appendMathToken("_", to: &output)
                appendMathToken(groupedScriptOperand(lower), to: &output)
            }
            if let upper = limits?.upper {
                appendMathToken("^", to: &output)
                appendMathToken(groupedScriptOperand(upper), to: &output)
            }
        }
    }

    private static func groupedFractionOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedScriptOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedMathOperand(_ nodes: [MathNode]) -> String {
        let plain = mathPlainText(from: nodes)
        guard nodes.count != 1 || !isAtomicFractionOperand(nodes[0]) else {
            return plain
        }
        return "(\(plain))"
    }

    private static func isAtomicFractionOperand(_ node: MathNode) -> Bool {
        switch node {
        case .number, .variable, .text, .symbol:
            return true
        default:
            return false
        }
    }

    private static func containsLossyAccessibilityNode(in nodes: [MathNode]) -> Bool {
        nodes.contains(where: containsLossyAccessibilityNode)
    }

    private static func containsLossyAccessibilityNode(_ node: MathNode) -> Bool {
        switch node {
        case .accent:
            // Omitting an accent changes the expression. Until a spoken accent
            // vocabulary is available, preserve exact TeX instead.
            return true
        case .fraction(let numerator, let denominator):
            return containsLossyAccessibilityNode(in: numerator)
                || containsLossyAccessibilityNode(in: denominator)
        case .superscript(let base, let exponent):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: exponent)
        case .subscript(let base, let index):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: index)
        case .subSuperscript(let base, let sub, let sup):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: sub)
                || containsLossyAccessibilityNode(in: sup)
        case .sqrt(let index, let radicand):
            return (index.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || containsLossyAccessibilityNode(in: radicand)
        case .group(let body), .font(_, let body):
            return containsLossyAccessibilityNode(in: body)
        case .leftRight(_, _, let body):
            return containsLossyAccessibilityNode(in: body)
        case .matrix(let rows, _), .environment(_, let rows):
            return rows.flatMap { $0 }.contains { containsLossyAccessibilityNode(in: $0) }
        case .bigOperator(_, let limits):
            return (limits?.lower.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || (limits?.upper.map { containsLossyAccessibilityNode(in: $0) } ?? false)
        case .number, .variable, .operator, .symbol, .text, .space:
            return false
        }
    }

    private static func appendMathOperator(_ op: MathOperator, to output: inout String) {
        let text: String
        switch op {
        case .plus: text = "+"
        case .minus: text = "−"
        case .times: text = "×"
        case .div: text = "÷"
        case .cdot: text = "·"
        case .pm: text = "±"
        case .mp: text = "∓"
        case .star: text = "*"
        case .equal: text = "="
        case .lessThan: text = "<"
        case .greaterThan: text = ">"
        case .leq: text = "≤"
        case .geq: text = "≥"
        case .neq: text = "≠"
        case .approx: text = "≈"
        case .equiv: text = "≡"
        case .sim: text = "∼"
        case .in: text = "∈"
        case .subset: text = "⊂"
        case .supset: text = "⊃"
        case .subseteq: text = "⊆"
        case .supseteq: text = "⊇"
        case .cup: text = "∪"
        case .cap: text = "∩"
        case .to, .rightarrow: text = "→"
        case .leftarrow: text = "←"
        case .mapsto: text = "↦"
        case .colon: text = ":"
        case .comma: text = ","
        case .semicolon: text = ";"
        case .bang: text = "!"
        }
        appendSpacedMathToken(text, to: &output)
    }

    private static func appendMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        if isArrowToken(token) {
            appendSpacedMathToken(token, to: &output)
        } else {
            output.append(token)
        }
    }

    private static func appendSpacedMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        appendSpace(to: &output)
        output.append(token)
        appendSpace(to: &output)
    }

    private static func appendSpace(to output: inout String) {
        if output.last?.isWhitespace != true {
            output.append(" ")
        }
    }

    private static func isArrowToken(_ token: String) -> Bool {
        ["→", "←", "↔", "⇒", "⇐", "⇔", "⟹", "⟸", "⟺", "↦"].contains(token)
    }

    private static func delimiterText(_ delimiter: Delimiter) -> String {
        switch delimiter {
        case .paren: return "("
        case .closeParen: return ")"
        case .bracket: return "["
        case .closeBracket: return "]"
        case .brace: return "{"
        case .closeBrace: return "}"
        case .pipe: return "|"
        case .doublePipe: return "‖"
        case .angle: return "⟨"
        case .closeAngle: return "⟩"
        case .none: return ""
        }
    }

    private static func bigOperatorText(_ kind: BigOpKind) -> String {
        switch kind {
        case .sum: return "∑"
        case .prod: return "∏"
        case .coprod: return "∐"
        case .int: return "∫"
        case .iint: return "∬"
        case .iiint: return "∭"
        case .oint: return "∮"
        case .bigcup: return "⋃"
        case .bigcap: return "⋂"
        case .bigoplus: return "⨁"
        case .bigotimes: return "⨂"
        case .lim: return "lim"
        case .sup: return "sup"
        case .inf: return "inf"
        case .min: return "min"
        case .max: return "max"
        case .det: return "det"
        case .log: return "log"
        case .ln: return "ln"
        case .sin: return "sin"
        case .cos: return "cos"
        case .tan: return "tan"
        case .exp: return "exp"
        }
    }

    private static func mathSymbolText(_ symbol: MathSymbol) -> String {
        switch symbol {
        case .alpha: return "α"
        case .beta: return "β"
        case .gamma: return "γ"
        case .delta: return "δ"
        case .epsilon, .varepsilon: return "ε"
        case .zeta: return "ζ"
        case .eta: return "η"
        case .theta, .vartheta: return "θ"
        case .iota: return "ι"
        case .kappa: return "κ"
        case .lambda: return "λ"
        case .mu: return "μ"
        case .nu: return "ν"
        case .xi: return "ξ"
        case .pi: return "π"
        case .rho, .varrho: return "ρ"
        case .sigma, .varsigma: return "σ"
        case .tau: return "τ"
        case .upsilon: return "υ"
        case .phi, .varphi: return "φ"
        case .chi: return "χ"
        case .psi: return "ψ"
        case .omega: return "ω"
        case .capitalGamma: return "Γ"
        case .capitalDelta: return "Δ"
        case .capitalTheta: return "Θ"
        case .capitalLambda: return "Λ"
        case .capitalXi: return "Ξ"
        case .capitalPi: return "Π"
        case .capitalSigma: return "Σ"
        case .capitalUpsilon: return "Υ"
        case .capitalPhi: return "Φ"
        case .capitalPsi: return "Ψ"
        case .capitalOmega: return "Ω"
        case .infty: return "∞"
        case .partial: return "∂"
        case .nabla: return "∇"
        case .forall: return "∀"
        case .exists: return "∃"
        case .neg: return "¬"
        case .ell: return "ℓ"
        case .hbar: return "ℏ"
        case .emptyset: return "∅"
        case .cdots: return "⋯"
        case .ldots: return "…"
        case .vdots: return "⋮"
        case .ddots: return "⋱"
        case .prime: return "′"
        case .top: return "⊤"
        }
    }

    // MARK: - Image URL Resolution

    /// Split paragraph inlines around resolvable markdown images.
    ///
    /// Image-only paragraphs become a single `.image` segment. Mixed paragraphs
    /// become text/image/text segments so syntax like
    /// `Before ![diagram](diagram.jpeg) after` renders the JPEG instead of the
    /// bracketed alt-text fallback.
    private static func resolveParagraphImageSegments(
        inlines: [MarkdownInline],
        palette: ThemePalette,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String? = nil
    ) -> [Self]? {
        #if DEBUG
        warnIfRelativeImagesNeedWorkspaceContext(inlines: inlines, workspaceID: workspaceID)
        #endif

        var segments: [Self] = []
        var pendingInlines: [MarkdownInline] = []
        var promotedAnyImage = false

        func flushPendingInlines() {
            guard inlineChunkHasVisibleFallback(pendingInlines) else {
                pendingInlines.removeAll(keepingCapacity: true)
                return
            }

            let attributed = attributedString(for: .paragraph(pendingInlines), palette: palette)
            if !attributed.characters.isEmpty {
                segments.append(.text(attributed))
            }
            pendingInlines.removeAll(keepingCapacity: true)
        }

        for inline in inlines {
            if case .image(let alt, let source) = inline,
               let imageURL = resolveImageURL(
                   source: source,
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   serverBaseURL: serverBaseURL,
                   sourceDirectory: sourceDirectory
               ) {
                flushPendingInlines()
                segments.append(.image(alt: alt, url: imageURL))
                promotedAnyImage = true
            } else {
                pendingInlines.append(inline)
            }
        }

        flushPendingInlines()
        return promotedAnyImage ? segments : nil
    }

    #if DEBUG
    private static func warnIfRelativeImagesNeedWorkspaceContext(
        inlines: [MarkdownInline],
        workspaceID: String?
    ) {
        guard workspaceID == nil else { return }
        for inline in inlines {
            if case .image(_, let source) = inline,
               let source, !source.isEmpty,
               !source.hasPrefix("data:"),
               !source.hasPrefix("http://"),
               !source.hasPrefix("https://"),
               !source.hasPrefix("/"),
               !source.hasPrefix("~") {
                print("[FlatSegment] WARNING: relative image but workspaceID is nil — workspace context not threaded to this rendering path")
                return
            }
        }
    }
    #endif

    private static func inlineChunkHasVisibleFallback(_ inlines: [MarkdownInline]) -> Bool {
        for inline in inlines {
            switch inline {
            case .text(let string), .html(let string), .code(let string):
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .image:
                return true
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children),
                 .link(let children, _):
                if inlineChunkHasVisibleFallback(children) {
                    return true
                }
            case .softBreak, .hardBreak:
                continue
            }
        }
        return false
    }

    /// Resolve a markdown image source to a loadable URL.
    ///
    /// Handles two cases:
    /// - **Relative paths** (e.g. `screenshots/img.jpeg`): resolved against
    ///   the workspace file API when `workspaceID` and `serverBaseURL` are set.
    /// - **Absolute URLs** (e.g. `https://example.com/photo.jpg`): passed
    ///   through directly for `NativeMarkdownImageView` to show as tap-to-load
    ///   remote images.
    ///
    /// Skips `data:` URIs (too large to display inline).
    private static func resolveImageURL(
        source: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String? = nil
    ) -> URL? {
        guard let source, !source.isEmpty else { return nil }

        // Skip data: URIs — they can be huge and aren't practical inline.
        if source.hasPrefix("data:") {
            return nil
        }

        // Absolute URL (http/https) — pass through directly.
        if let url = URL(string: source), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }

        // Local and absolute filesystem paths are intentionally not previewed.
        // Tools should return stored attachments or workspace-relative paths.
        if (URL(string: source)?.scheme == "file") || source.hasPrefix("/") || source.hasPrefix("~") {
            return nil
        }

        // Relative path — resolve against workspace file API.
        guard let workspaceID, !workspaceID.isEmpty,
              let baseURL = serverBaseURL else {
            return nil
        }

        // Resolve relative path against the markdown file's directory.
        // e.g. sourceDirectory="docs/", source="images/foo.png" → "docs/images/foo.png"
        var resolvedPath = source
        if let dir = sourceDirectory, !dir.isEmpty {
            resolvedPath = (dir as NSString).appendingPathComponent(source)
        }

        return WorkspaceFileURL.make(baseURL: baseURL, workspaceID: workspaceID, filePath: resolvedPath)
    }

    // MARK: - Inline Markdown Rendering

    /// Render markdown source to a single `NSAttributedString` for simple
    /// contexts where block-level subviews (code containers, tables) aren't
    /// needed.
    ///
    /// Used for user message bubbles — renders all blocks inline with styled
    /// attributed text. Code blocks become monospaced text, tables become
    /// pipe-delimited rows, and text blocks get full inline formatting
    /// (bold, italic, code, links, blockquotes, lists).
    static func renderMarkdownInline(
        _ markdown: String,
        defaultTextColor: UIColor,
        palette: ThemePalette
    ) -> NSAttributedString {
        let blocks = parseCommonMark(markdown)
        guard !blocks.isEmpty else {
            return NSAttributedString(string: markdown, attributes: [
                .font: AppFont.messageBody,
                .foregroundColor: defaultTextColor,
            ])
        }

        let result = NSMutableAttributedString()
        let paragraphSep = NSAttributedString(string: "\n\n")

        for (i, block) in blocks.enumerated() {
            if i > 0 {
                result.append(paragraphSep)
            }

            switch block {
            case .codeBlock(_, let code):
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                let codeFont = Self.monospacedFont(forTextStyle: .subheadline, baseSize: 12)
                result.append(NSAttributedString(string: trimmed, attributes: [
                    .font: codeFont,
                    .foregroundColor: UIColor(palette.mdCode),
                    .backgroundColor: UIColor(palette.bgHighlight),
                ]))

            case .thematicBreak:
                result.append(NSAttributedString(string: "───", attributes: [
                    .foregroundColor: UIColor(palette.comment),
                    .font: AppFont.messageBody,
                ]))

            case .table(let headers, let rows):
                let codeFont = Self.monospacedFont(forTextStyle: .subheadline, baseSize: 12)
                var lines: [String] = []
                let headerTexts = headers.map { plainText(from: $0) }
                lines.append(headerTexts.joined(separator: " | "))
                lines.append(headerTexts.map { String(repeating: "─", count: max($0.count, 3)) }.joined(separator: " | "))
                for row in rows {
                    lines.append(row.map { plainText(from: $0) }.joined(separator: " | "))
                }
                result.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                    .font: codeFont,
                    .foregroundColor: defaultTextColor,
                ]))

            default:
                let attributed = attributedString(
                    for: block, palette: palette, defaultTextColor: defaultTextColor
                )
                result.append(NSAttributedString(attributed))
            }
        }

        return result
    }

    // MARK: - Block → AttributedString

    private static func attributedString(
        for block: MarkdownBlock,
        palette: ThemePalette,
        defaultTextColor: UIColor? = nil
    ) -> AttributedString {
        switch block {
        case .heading(let level, let inlines):
            let font = Self.headingFont(level: level)
            let color = Self.headingColor(level: level, palette: palette)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacingBefore = Self.headingSpacingAbove(level: level)

            // Fast path: single text inline heading (common for simple headings).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                let heading = NSAttributedString(string: string, attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ])
                return AttributedString(heading)
            }

            let renderedInlines = renderInlines(inlines, palette: palette)
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(renderedInlines))
            mutable.addAttributes(
                [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ],
                range: NSRange(location: 0, length: mutable.length)
            )
            return AttributedString(mutable)

        case .paragraph(let inlines):
            let bodyFont = AppFont.messageBody
            let bodyColor = defaultTextColor ?? UIColor(palette.fg)
            if let renderedLatex = renderInlineLatexParagraph(
                inlines,
                palette: palette,
                bodyColor: bodyColor,
                bodyFont: bodyFont
            ) {
                return renderedLatex
            }
            if let renderedLatex = renderBareInlineLatexText(inlines) {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = bodyColor
                container.uiKit.font = bodyFont
                return AttributedString(renderedLatex, attributes: container)
            }
            // Fast path: single text inline (most common paragraph shape).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = bodyColor
                container.uiKit.font = bodyFont
                return AttributedString(string, attributes: container)
            }
            // Build with foreground baked into initial construction,
            // then override specific inline colors (code, links) by range.
            var result = renderInlinesWithDefaultColor(inlines, palette: palette, defaultColor: bodyColor)
            // Set body font on runs that don't have an explicit font (plain text).
            // Inline code already has monospace font set; this preserves it.
            for run in result.runs {
                if run.uiKit.font == nil {
                    result[run.range].uiKit.font = bodyFont
                }
            }
            return result

        case .blockQuote(let children):
            var result = AttributedString("▎ ")
            result.uiKit.foregroundColor = UIColor(palette.mdQuoteBorder)
            for (i, child) in children.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                result.append(attributedString(for: child, palette: palette, defaultTextColor: defaultTextColor))
            }
            result.uiKit.foregroundColor = UIColor(palette.mdQuote)
            return result

        case .unorderedList(let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var bullet = AttributedString("  • ")
                bullet.uiKit.foregroundColor = UIColor(palette.mdListBullet)
                result.append(bullet)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n    ")) }
                    result.append(attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor))
                }
            }
            return result

        case .orderedList(let start, let items):
            let listFont = Self.listBodyFont()
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var num = AttributedString("  \(start + i). ")
                num.uiKit.foregroundColor = UIColor(palette.mdListBullet)
                num.uiKit.font = listFont
                result.append(num)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    var content = attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor)
                    Self.applyListFont(to: &content, listFont: listFont)
                    result.append(content)
                }
            }
            return result

        case .taskList(let items):
            var result = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                if item.checked {
                    var check = AttributedString("  \u{25C9} ")
                    check.uiKit.foregroundColor = UIColor(palette.green)
                    result.append(check)
                } else {
                    var check = AttributedString("  \u{25CB} ")
                    check.uiKit.foregroundColor = UIColor(palette.fgDim)
                    result.append(check)
                }
                for (j, block) in item.content.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    var content = attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor)
                    if item.checked {
                        content.uiKit.foregroundColor = UIColor(palette.comment)
                        content.strikethroughStyle = .single
                    }
                    result.append(content)
                }
            }
            return result

        case .htmlBlock(let html):
            var result = AttributedString(html.trimmingCharacters(in: .whitespacesAndNewlines))
            result.uiKit.font = Self.monospacedFont(forTextStyle: .caption1)
            result.uiKit.foregroundColor = UIColor(palette.comment)
            return result

        case .codeBlock, .table, .thematicBreak:
            return AttributedString()
        }
    }

    // MARK: - Inline → AttributedString (range-based construction)

    /// Attribute overlay to apply to a substring range.
    private struct InlineAttr {
        let utf8Start: Int
        let utf8End: Int
        let apply: (inout AttributedSubstring) -> Void
    }

    /// Build an AttributedString from inlines by extracting plain text first,
    /// then applying attributes by range. Avoids creating N intermediate
    /// AttributedString objects and the overhead of N append operations.
    private static func renderInlines(_ inlines: [MarkdownInline], palette: ThemePalette) -> AttributedString {
        return renderInlinesCore(inlines, palette: palette, defaultColor: nil)
    }

    /// Like `renderInlines` but bakes a default foreground color into the
    /// initial AttributedString construction, avoiding an O(runs) post-set.
    private static func renderInlinesWithDefaultColor(
        _ inlines: [MarkdownInline],
        palette: ThemePalette,
        defaultColor: UIColor
    ) -> AttributedString {
        return renderInlinesCore(inlines, palette: palette, defaultColor: defaultColor)
    }

    private static func renderInlinesCore(
        _ inlines: [MarkdownInline],
        palette: ThemePalette,
        defaultColor: UIColor?
    ) -> AttributedString {
        // Fast path: single text inline (most common paragraph).
        if inlines.count == 1, case .text(let string) = inlines[0] {
            if let color = defaultColor {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = color
                return AttributedString(string, attributes: container)
            }
            return AttributedString(string)
        }
        // Fast path: single non-text inline.
        if inlines.count == 1 {
            var result = renderInlineFallback(inlines[0], palette: palette)
            if let color = defaultColor {
                result.uiKit.foregroundColor = color
            }
            return result
        }

        // Build plain text and collect attribute overlays.
        var plainText = ""
        var attrs: [InlineAttr] = []
        collectInlineText(inlines, palette: palette, into: &plainText, attrs: &attrs, depth: 0)

        guard !plainText.isEmpty else { return AttributedString() }

        // Create with default color baked in if provided.
        var result: AttributedString
        if let color = defaultColor {
            var container = AttributeContainer()
            container.uiKit.foregroundColor = color
            result = AttributedString(plainText, attributes: container)
        } else {
            result = AttributedString(plainText)
        }

        // Apply overlays by range.
        let utf8View = plainText.utf8
        for attr in attrs {
            let startIdx = utf8View.index(utf8View.startIndex, offsetBy: attr.utf8Start)
            let endIdx = utf8View.index(utf8View.startIndex, offsetBy: attr.utf8End)
            let startStrIdx = String.Index(startIdx, within: plainText) ?? plainText.startIndex
            let endStrIdx = String.Index(endIdx, within: plainText) ?? plainText.endIndex
            guard let attrStart = AttributedString.Index(startStrIdx, within: result),
                  let attrEnd = AttributedString.Index(endStrIdx, within: result) else { continue }
            if attrStart < attrEnd {
                attr.apply(&result[attrStart ..< attrEnd])
            }
        }

        return result
    }

    private static func imageFallbackText(alt: String) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[image]" : "[\(trimmed)]"
    }

    /// Recursively extract plain text from inlines and record attribute ranges.
    private static func collectInlineText(
        _ inlines: [MarkdownInline],
        palette: ThemePalette,
        into text: inout String,
        attrs: inout [InlineAttr],
        depth: Int
    ) {
        for inline in inlines {
            let start = text.utf8.count
            switch inline {
            case .text(let string):
                text += string
            case .emphasis(let children):
                collectInlineText(children, palette: palette, into: &text, attrs: &attrs, depth: depth + 1)
                let end = text.utf8.count
                if end > start {
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.inlinePresentationIntent = .emphasized
                    })
                }
            case .strong(let children):
                collectInlineText(children, palette: palette, into: &text, attrs: &attrs, depth: depth + 1)
                let end = text.utf8.count
                if end > start {
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.inlinePresentationIntent = .stronglyEmphasized
                    })
                }
            case .code(let code):
                text += code
                let end = text.utf8.count
                let codeFont = Self.monospacedFont(forTextStyle: .subheadline)
                let codeFg = UIColor(palette.mdCode)
                let codeBg = UIColor(palette.bgHighlight)
                attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                    sub.uiKit.font = codeFont
                    sub.uiKit.foregroundColor = codeFg
                    sub.uiKit.backgroundColor = codeBg
                })
            case .link(let children, let destination):
                collectInlineText(children, palette: palette, into: &text, attrs: &attrs, depth: depth + 1)
                let end = text.utf8.count
                if end > start {
                    let resolvedURL: URL? = {
                        guard let destination, let url = URL(string: destination), url.scheme != nil else { return nil }
                        return url
                    }()
                    let linkColor = UIColor(palette.mdLink)
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.uiKit.foregroundColor = linkColor
                        sub.underlineStyle = .single
                        if let url = resolvedURL {
                            sub.link = url
                        }
                    })
                }
            case .image(let alt, _):
                text += imageFallbackText(alt: alt)
                let end = text.utf8.count
                attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                    sub.uiKit.foregroundColor = UIColor(palette.comment)
                })
            case .softBreak, .hardBreak:
                text += "\n"
            case .html(let raw):
                text += raw
                let end = text.utf8.count
                attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                    sub.uiKit.foregroundColor = UIColor(palette.comment)
                })
            case .strikethrough(let children):
                collectInlineText(children, palette: palette, into: &text, attrs: &attrs, depth: depth + 1)
                let end = text.utf8.count
                if end > start {
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.strikethroughStyle = .single
                    })
                }
            }
        }
    }

    /// Fallback for single complex inlines (non-text). Uses the old append-based path.
    private static func renderInlineFallback(_ inline: MarkdownInline, palette: ThemePalette) -> AttributedString {
        switch inline {
        case .text(let string):
            return AttributedString(string)
        case .emphasis(let children):
            var result = renderInlines(children, palette: palette)
            result.inlinePresentationIntent = .emphasized
            return result
        case .strong(let children):
            var result = renderInlines(children, palette: palette)
            result.inlinePresentationIntent = .stronglyEmphasized
            return result
        case .code(let code):
            var result = AttributedString(code)
            result.uiKit.font = monospacedFont(forTextStyle: .subheadline)
            result.uiKit.foregroundColor = UIColor(palette.mdCode)
            result.uiKit.backgroundColor = UIColor(palette.bgHighlight)
            return result
        case .link(let children, let destination):
            var result = renderInlines(children, palette: palette)
            result.uiKit.foregroundColor = UIColor(palette.mdLink)
            result.underlineStyle = .single
            if let destination,
               let url = URL(string: destination),
               url.scheme != nil {
                result.link = url
            }
            return result
        case .image(let alt, _):
            var result = AttributedString(imageFallbackText(alt: alt))
            result.uiKit.foregroundColor = UIColor(palette.comment)
            return result
        case .softBreak, .hardBreak:
            return AttributedString("\n")
        case .html(let raw):
            var result = AttributedString(raw)
            result.uiKit.foregroundColor = UIColor(palette.comment)
            return result
        case .strikethrough(let children):
            var result = renderInlines(children, palette: palette)
            result.strikethroughStyle = .single
            return result
        }
    }

    // MARK: - UIFont Helpers

    private static func headingFont(level: Int) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: .body)
        switch level {
        case 1: return metrics.scaledFont(for: .systemFont(ofSize: 21, weight: .bold))
        case 2: return metrics.scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        case 3: return metrics.scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        case 4: return metrics.scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        case 5: return metrics.scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
        default: return metrics.scaledFont(for: .systemFont(ofSize: 15, weight: .regular))
        }
    }

    private static func headingColor(level: Int, palette: ThemePalette) -> UIColor {
        switch level {
        case 1, 2: return UIColor(palette.mdHeading)
        case 3: return UIColor(palette.fg)
        case 4, 5: return UIColor(palette.fgDim)
        default: return UIColor(palette.comment)
        }
    }

    private static func headingSpacingAbove(level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 16
        case 3: return 12
        case 4: return 8
        default: return 6
        }
    }

    private static func monospacedFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
        monospacedFont(forTextStyle: style, baseSize: style == .caption1 ? 11 : 12)
    }

    private static func monospacedFont(forTextStyle style: UIFont.TextStyle, baseSize: CGFloat) -> UIFont {
        FontPreferences.scaledCodeFont(baseSize: baseSize, textStyle: style)
    }

    /// Body font bumped one point for list items (Dynamic Type aware).
    private static func listBodyFont() -> UIFont {
        let bodySize = AppFont.messageBody.pointSize
        // If using mono for messages, return the mono font at body+1 size
        if FontPreferences.useMonoForMessages {
            return FontPreferences.codeFont.font(size: bodySize + 1, weight: .regular)
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: bodySize + 1)
        )
    }

    /// Replace body-sized fonts in an attributed string with the list font.
    /// Preserves monospace (inline code) and other special fonts.
    private static func applyListFont(to content: inout AttributedString, listFont: UIFont) {
        let bodySize = AppFont.messageBody.pointSize
        for run in content.runs {
            if let font = run.uiKit.font {
                if font.pointSize == bodySize,
                   !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
                    content[run.range].uiKit.font = listFont
                }
            } else {
                content[run.range].uiKit.font = listFont
            }
        }
    }
}
