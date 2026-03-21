import SwiftUI
import UIKit

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
        serverBaseURL: URL? = nil
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

        for block in blocks {
            switch block {
            case .codeBlock(let language, let code):
                flushPendingText()
                result.append(.codeBlock(language: language, code: code))

            case .table(let headers, let rows):
                flushPendingText()
                result.append(.table(headers: headers, rows: rows))

            case .thematicBreak:
                flushPendingText()
                result.append(.thematicBreak)

            case .paragraph(let inlines):
                // Promote image-only paragraphs to a standalone `.image` segment
                // when workspace context is available and the source is a relative path.
                if let imageURL = resolveStandaloneImage(
                    inlines: inlines,
                    workspaceID: workspaceID,
                    serverBaseURL: serverBaseURL
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

            default:
                let attributed = Self.attributedString(for: block, palette: palette)
                appendTextBlock(attributed)
            }
        }

        flushPendingText()
        return result
    }

    // MARK: - Image URL Resolution

    /// Return a fully resolved workspace file URL if `inlines` contains exactly
    /// one `.image` node with a relative path and workspace context is available.
    private static func resolveStandaloneImage(
        inlines: [MarkdownInline],
        workspaceID: String?,
        serverBaseURL: URL?
    ) -> URL? {
        guard inlines.count == 1,
              case .image(_, let source) = inlines[0],
              let source,
              !source.isEmpty,
              let workspaceID,
              !workspaceID.isEmpty,
              let baseURL = serverBaseURL else {
            return nil
        }

        // Only handle relative paths — skip data: URIs and absolute URLs.
        if source.contains("://") || source.hasPrefix("data:") {
            return nil
        }

        return WorkspaceFileURL.make(baseURL: baseURL, workspaceID: workspaceID, filePath: source)
    }

    // MARK: - Block → AttributedString

    private static func attributedString(for block: MarkdownBlock, palette: ThemePalette) -> AttributedString {
        switch block {
        case .heading(let level, let inlines):
            // Font stays in SwiftUI scope (normalizedAttributedText fills body fallback).
            let font: Font = switch level {
            case 1: .title.bold()
            case 2: .title2.bold()
            case 3: .title3.bold()
            case 4: .headline
            case 5: .subheadline.bold()
            default: .subheadline
            }
            // Fast path: single text inline heading (common for simple headings).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = UIColor(palette.fg)
                container.font = font
                return AttributedString(string, attributes: container)
            }
            var result = renderInlines(inlines, palette: palette)
            result.uiKit.foregroundColor = UIColor(palette.fg)
            result.font = font
            return result

        case .paragraph(let inlines):
            // Fast path: single text inline (most common paragraph shape).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = UIColor(palette.fg)
                return AttributedString(string, attributes: container)
            }
            // Build with foreground baked into initial construction,
            // then override specific inline colors (code, links) by range.
            return renderInlinesWithDefaultColor(inlines, palette: palette, defaultColor: UIColor(palette.fg))

        case .blockQuote(let children):
            var result = AttributedString("▎ ")
            result.uiKit.foregroundColor = UIColor(palette.purple)
            for (i, child) in children.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                result.append(attributedString(for: child, palette: palette))
            }
            result.uiKit.foregroundColor = UIColor(palette.fgDim)
            return result

        case .unorderedList(let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var bullet = AttributedString("  • ")
                bullet.uiKit.foregroundColor = UIColor(palette.fgDim)
                result.append(bullet)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n    ")) }
                    result.append(attributedString(for: block, palette: palette))
                }
            }
            return result

        case .orderedList(let start, let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var num = AttributedString("  \(start + i). ")
                num.uiKit.foregroundColor = UIColor(palette.fgDim)
                result.append(num)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    result.append(attributedString(for: block, palette: palette))
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
                    var content = attributedString(for: block, palette: palette)
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
            result.font = .system(.caption, design: .monospaced)
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
                let codeColor = UIColor(palette.cyan)
                attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                    sub.font = .system(.body, design: .monospaced)
                    sub.uiKit.foregroundColor = codeColor
                })
            case .link(let children, let destination):
                collectInlineText(children, palette: palette, into: &text, attrs: &attrs, depth: depth + 1)
                let end = text.utf8.count
                if end > start {
                    let resolvedURL: URL? = {
                        guard let destination, let url = URL(string: destination), url.scheme != nil else { return nil }
                        return url
                    }()
                    let linkColor = UIColor(palette.blue)
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
                    let commentColor = UIColor(palette.comment)
                    attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                        sub.uiKit.foregroundColor = commentColor
                    })
                }
            case .softBreak, .hardBreak:
                text += "\n"
            case .html(let raw):
                text += raw
                let end = text.utf8.count
                let commentColor = UIColor(palette.comment)
                attrs.append(InlineAttr(utf8Start: start, utf8End: end) { sub in
                    sub.uiKit.foregroundColor = commentColor
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
            result.font = .system(.body, design: .monospaced)
            result.uiKit.foregroundColor = UIColor(palette.cyan)
            return result
        case .link(let children, let destination):
            var result = renderInlines(children, palette: palette)
            result.uiKit.foregroundColor = UIColor(palette.blue)
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
}
