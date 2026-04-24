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
        workspaceID: String? = nil
    ) -> [FlatSegment]? {
        guard shouldCache(content) else { return nil }
        let key = stableKey(for: content, themeID: themeID, workspaceID: workspaceID)
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
        workspaceID: String? = nil,
        segments: [FlatSegment]
    ) {
        let sourceBytes = content.utf8.count
        guard sourceBytes <= maxEntrySourceBytes else { return }

        let key = stableKey(for: content, themeID: themeID, workspaceID: workspaceID)
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

    private func stableKey(for content: String, themeID: ThemeID, workspaceID: String? = nil) -> UInt64 {
        // FNV-1a 64-bit hash (stable across process launches).
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in themeID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        // Separator to avoid accidental collisions between field boundaries.
        hash ^= 0xFF
        hash &*= 1_099_511_628_211

        for byte in (workspaceID ?? "").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        hash ^= 0xFE
        hash &*= 1_099_511_628_211

        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - Shared Workspace File URL Helpers

enum WorkspaceFileURL {
    /// Build `{base}/workspaces/{workspaceID}/files/{path}`.
    static func make(baseURL: URL, workspaceID: String, filePath: String) -> URL? {
        guard !workspaceID.isEmpty else { return nil }
        let normalizedPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
        guard !normalizedPath.isEmpty else { return nil }

        return baseURL
            .appendingPathComponent("workspaces")
            .appendingPathComponent(workspaceID)
            .appendingPathComponent("files")
            .appendingPathComponent(normalizedPath)
    }

    /// Parse `{base}/workspaces/{workspaceID}/files/{path}`.
    static func parse(_ url: URL) -> (workspaceID: String, filePath: String)? {
        let components = url.pathComponents

        guard let workspaceIndex = components.firstIndex(of: "workspaces"),
              components.count > workspaceIndex + 1 else {
            return nil
        }

        let workspaceID = components[workspaceIndex + 1]
        guard !workspaceID.isEmpty else { return nil }

        let filesSearchStart = workspaceIndex + 2
        guard filesSearchStart < components.count,
              let filesIndex = components[filesSearchStart..<components.count].firstIndex(of: "files"),
              components.count > filesIndex + 1 else {
            return nil
        }

        let filePath = components[(filesIndex + 1)...].joined(separator: "/")
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
    /// When `workspaceID` and `serverBaseURL` are provided, paragraphs that
    /// contain a single relative-path image inline are promoted to `.image`
    /// segments instead of the alt-text fallback.
    /// Cached paragraph separator. Created once to avoid repeated allocation.
    private static let paragraphSeparator = AttributedString("\n\n")

    static func build(
        from blocks: [MarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        /// Directory path of the source markdown file (e.g. "docs/").
        /// Used to resolve relative image paths like `images/foo.png`
        /// → `docs/images/foo.png` in the workspace.
        sourceDirectory: String? = nil
    ) -> [Self] {
        let palette = themeID.palette
        var result: [Self] = []
        result.reserveCapacity(blocks.count)

        var pendingText = AttributedString()
        var hasPendingText = false

        func flushPendingText() {
            guard hasPendingText, !pendingText.characters.isEmpty else { return }
            result.append(.text(pendingText))
            pendingText = AttributedString()
            hasPendingText = false
        }

        func appendTextBlock(_ attributed: AttributedString) {
            guard !attributed.characters.isEmpty else { return }
            if hasPendingText {
                pendingText.append(paragraphSeparator)
            }
            pendingText.append(attributed)
            hasPendingText = true
        }

        func appendCodeSegment(language: String?, code: String) {
            if let lang = language, SyntaxLanguage.detect(lang) == .mermaid {
                result.append(.mermaidDiagram(code: code))
            } else if let lang = language, SyntaxLanguage.detect(lang) == .latex {
                result.append(.latexBlock(code: code))
            } else {
                result.append(.codeBlock(language: language, code: code))
            }
        }

        // Render list item text as attributed lines, but keep nested block-level
        // nodes (fenced code, tables, thematic breaks) as standalone segments.
        // This preserves code fences inside list items instead of dropping them.
        func appendListBlock(
            items: [[MarkdownBlock]],
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
                appendTextBlock(merged)
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
                    var line = prefix
                    line.append(rendered)
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
                        appendCodeSegment(language: language, code: code)
                        emittedAnyRenderable = true

                    case .table(let headers, let rows):
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        result.append(.table(headers: headers, rows: rows))
                        emittedAnyRenderable = true

                    case .thematicBreak:
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        result.append(.thematicBreak)
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

        for block in blocks {
            switch block {
            case .codeBlock(let language, let code):
                flushPendingText()
                appendCodeSegment(language: language, code: code)

            case .table(let headers, let rows):
                flushPendingText()
                result.append(.table(headers: headers, rows: rows))

            case .thematicBreak:
                flushPendingText()
                result.append(.thematicBreak)

            case .paragraph(let inlines):
                // Promote standalone display-math paragraphs to `.latexBlock`
                // so assistant responses using `\[ ... \]` or `$$ ... $$`
                // render as formulas in the timeline.
                // Promote image-only paragraphs to a standalone `.image` segment
                // when the source is a resolvable URL (absolute or workspace-relative).
                if let latexSource = resolveStandaloneLatex(inlines: inlines) {
                    flushPendingText()
                    result.append(.latexBlock(code: latexSource))
                } else if let imageURL = resolveStandaloneImage(
                    inlines: inlines,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL,
                    sourceDirectory: sourceDirectory
                ) {
                    let alt = (inlines.first.flatMap {
                        if case .image(let a, _) = $0 { return a } else { return nil }
                    }) ?? ""
                    flushPendingText()
                    result.append(.image(alt: alt, url: imageURL))
                } else {
                    let attributed = Self.attributedString(for: block, palette: palette)
                    appendTextBlock(attributed)
                }

            case .unorderedList(let items):
                appendListBlock(
                    items: items,
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
                appendTextBlock(attributed)
            }
        }

        flushPendingText()
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
        guard isLikelyLatexMath(inner) else { return nil }
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
        guard (opening == "[" || opening == "\\["),
              (closing == "]" || closing == "\\]") else {
            return nil
        }

        let inner = lines[(firstNonEmpty + 1) ..< lastNonEmpty]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyLatexMath(inner) else { return nil }
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

    private static func isLikelyLatexMath(_ source: String) -> Bool {
        guard !source.isEmpty else { return false }

        // Strong signals for TeX math, without aggressively rewriting prose.
        if source.contains("\\") {
            return true
        }
        if source.contains("^") || source.contains("_") {
            return true
        }
        if source.contains("{") && source.contains("}") {
            return true
        }

        return false
    }

    // MARK: - Image URL Resolution

    /// Return a resolved URL if `inlines` contains exactly one `.image` node.
    ///
    /// Handles two cases:
    /// - **Relative paths** (e.g. `screenshots/img.png`): resolved against
    ///   the workspace file API when `workspaceID` and `serverBaseURL` are set.
    /// - **Absolute URLs** (e.g. `https://example.com/photo.jpg`): passed
    ///   through directly for `NativeMarkdownImageView` to fetch via URLSession.
    ///
    /// Skips `data:` URIs (too large to display inline).
    private static func resolveStandaloneImage(
        inlines: [MarkdownInline],
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String? = nil
    ) -> URL? {
        #if DEBUG
        if workspaceID == nil,
           inlines.count == 1,
           case .image(_, let source) = inlines[0],
           let source, !source.isEmpty,
           !source.hasPrefix("data:"),
           !source.hasPrefix("http://"),
           !source.hasPrefix("https://") {
            print("[FlatSegment] WARNING: relative image but workspaceID is nil — workspace context not threaded to this rendering path")
        }
        #endif
        guard inlines.count == 1,
              case .image(_, let source) = inlines[0],
              let source,
              !source.isEmpty else {
            return nil
        }

        // Skip data: URIs — they can be huge and aren't practical inline.
        if source.hasPrefix("data:") {
            return nil
        }

        // Absolute URL (http/https) — pass through directly.
        if let url = URL(string: source), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }

        // Absolute filesystem path — fetch through the session-scoped file API
        // so assistant messages can display freshly written files like
        // `/Users/.../pelican-bike.svg`.
        if source.hasPrefix("/") || source.hasPrefix("~") {
            guard let workspaceID, !workspaceID.isEmpty,
                  let sessionID, !sessionID.isEmpty else {
                return nil
            }
            return SessionFileURL.make(workspaceID: workspaceID, sessionID: sessionID, filePath: source)
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
                let codeSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                let codeFont = FontPreferences.codeFont.font(size: codeSize, weight: .regular)
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
                let codeSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                let codeFont = FontPreferences.codeFont.font(size: codeSize, weight: .regular)
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
                var container = AttributeContainer()
                container.uiKit.font = font
                container.uiKit.foregroundColor = color
                container.uiKit.paragraphStyle = paragraphStyle
                return AttributedString(string, attributes: container)
            }
            var result = renderInlines(inlines, palette: palette)
            result.uiKit.font = font
            result.uiKit.foregroundColor = color
            result.uiKit.paragraphStyle = paragraphStyle
            return result

        case .paragraph(let inlines):
            let bodyFont = AppFont.messageBody
            let bodyColor = defaultTextColor ?? UIColor(palette.fg)
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
                if !alt.isEmpty {
                    text += "[\(alt)]"
                    let end = text.utf8.count
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.uiKit.foregroundColor = UIColor(palette.comment)
                    })
                }
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
            if alt.isEmpty { return AttributedString() }
            var result = AttributedString("[\(alt)]")
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
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        return FontPreferences.codeFont.font(size: size, weight: .regular)
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
