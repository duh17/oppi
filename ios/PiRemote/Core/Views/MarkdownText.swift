// swiftlint:disable file_length
import os.log
import SwiftUI

private let perfLog = Logger(subsystem: "dev.chenda.PiRemote", category: "Markdown")

// MARK: - Global Segment Cache

/// Process-wide cache for parsed markdown segments.
///
/// Keyed by a stable content hash so scroll-back can hit instantly.
/// Bounded by both entry count and total source text bytes to avoid
/// retaining large markdown histories across session switches.
final class MarkdownSegmentCache: @unchecked Sendable {
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

    func get(_ content: String) -> [FlatSegment]? {
        guard shouldCache(content) else { return nil }
        let key = stableKey(for: content)
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        counter += 1
        entry.order = counter
        entries[key] = entry
        return entry.segments
    }

    func set(_ content: String, segments: [FlatSegment]) {
        let sourceBytes = content.utf8.count
        guard sourceBytes <= maxEntrySourceBytes else { return }

        let key = stableKey(for: content)
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

    private func stableKey(for content: String) -> UInt64 {
        // FNV-1a 64-bit hash (stable across process launches).
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Renders markdown text with full CommonMark support.
///
/// **Streaming mode** (`isStreaming: true`):
/// - Uses lightweight `parseCodeBlocks` splitter for code fences and tables
/// - Prose renders as plain text (no inline formatting) to stay within 33ms frame budget
/// - Unclosed code blocks render with chrome but skip syntax highlighting
///
/// **Finalized mode** (`isStreaming: false`):
/// - Full CommonMark parsing via apple/swift-markdown
/// - Headings, block quotes, lists, thematic breaks, tables, code blocks
/// - Inline: bold, italic, code, links, images (alt text), strikethrough
struct MarkdownText: View {
    let content: String
    let isStreaming: Bool

    /// Very large responses are rendered as plain text to avoid expensive
    /// markdown parsing/layout spikes that can trigger memory pressure.
    private static let plainTextFallbackThreshold = 20_000
    /// Placeholder height is clamped so huge messages don't allocate giant
    /// temporary layout regions before async parsing completes.
    private static let maxPlaceholderHeight: CGFloat = 480

    /// Cached parse result for streaming — avoids re-scanning on every render.
    @State private var cachedBlocks: [ContentBlock] = []
    @State private var cachedContentLength: Int = -1

    /// Cached render segments for finalized content.
    ///
    /// Built once from CommonMark blocks via `.task` on first appearance.
    /// Uses `FlatSegment` (AttributedString + code blocks) instead of raw
    /// MarkdownBlocks to avoid recomputing during layout passes.
    @State private var cachedSegments: [FlatSegment]?

    /// Raw CommonMark blocks — intermediate, only used during parsing.
    @State private var commonMarkBlocks: [MarkdownBlock]?

    init(_ content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
    }

    var body: some View {
        if isStreaming {
            streamingBody
        } else {
            finalizedBody
        }
    }

    @ViewBuilder
    private var finalizedBody: some View {
        if content.count > Self.plainTextFallbackThreshold {
            Text(content)
                .foregroundStyle(.tokyoFg)
                .textSelection(.enabled)
        } else if let segments = cachedSegments {
            FlatMarkdownView(segments: segments)
        } else if let cached = synchronousCacheLookup() {
            // Synchronous cache hit — render immediately without placeholder.
            // Critical for LazyVStack: avoids placeholder → content height
            // mismatch that triggers cascading re-layouts when recycled
            // views get their @State reset to nil on off-screen destruction.
            FlatMarkdownView(segments: cached)
                .onAppear { cachedSegments = cached }
        } else {
            // Cold start: no cache hit. Show placeholder and parse async.
            Color.clear
                .frame(height: placeholderHeight)
                .task {
                    let text = content
                    let shouldUseCache = MarkdownSegmentCache.shared.shouldCache(text)

                    // Double-check cache (might have been warmed while waiting)
                    if shouldUseCache,
                       let cached = MarkdownSegmentCache.shared.get(text) {
                        cachedSegments = cached
                        return
                    }

                    let start = ContinuousClock.now
                    let segments = await Task.detached {
                        let blocks = parseCommonMark(text)
                        return FlatSegment.build(from: blocks)
                    }.value
                    let elapsedMs = (ContinuousClock.now - start).ms
                    perfLog.error("PERF parseCommonMark: \(text.count) chars -> \(segments.count) segments in \(elapsedMs)ms")

                    if shouldUseCache {
                        MarkdownSegmentCache.shared.set(text, segments: segments)
                    }
                    cachedSegments = segments
                }
        }
    }

    /// Check global markdown cache synchronously during body evaluation.
    ///
    /// This is the critical path for preventing LazyVStack layout cascades.
    /// When a view is recycled (off-screen → on-screen), `@State cachedSegments`
    /// resets to nil. Without this synchronous check, the view would show a
    /// fixed-height placeholder, then async-update to the real content,
    /// causing a height mismatch that triggers cascading re-layouts across
    /// all items — freezing the main thread for 50+ seconds.
    private func synchronousCacheLookup() -> [FlatSegment]? {
        guard MarkdownSegmentCache.shared.shouldCache(content) else { return nil }
        return MarkdownSegmentCache.shared.get(content)
    }

    private var placeholderHeight: CGFloat {
        let estimated = max(20, CGFloat(content.count / 60) * 18)
        return min(estimated, Self.maxPlaceholderHeight)
    }

    // MARK: - Streaming Body

    private var streamingBody: some View {
        let blocks = cachedBlocks
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    Text(text)
                        .foregroundStyle(.tokyoFg)
                        .textSelection(.enabled)

                case .codeBlock(let language, let code, let isComplete):
                    if !isComplete {
                        StreamingCodeBlockView(language: language, code: code)
                    } else {
                        CodeBlockView(language: language, code: code)
                    }

                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                }
            }
        }
        .onAppear { refreshBlocksIfNeeded() }
        .onChange(of: content.count) { _, _ in refreshBlocksIfNeeded() }
    }

    private func refreshBlocksIfNeeded() {
        guard content.count != cachedContentLength else { return }
        cachedBlocks = parseCodeBlocks(content)
        cachedContentLength = content.count
    }
}

// MARK: - Flat Markdown View (Performance-Optimized)

/// Renders CommonMark blocks as a flat list with minimal view nesting.
///
/// **Key design**: inline content (paragraphs, headings, lists, block quotes)
/// is rendered as `Text(AttributedString)` — a single view per text run.
/// Only code blocks and tables get dedicated sub-views.
///
/// This avoids the deep VStack + AnyView tree of `CommonMarkView` that caused
/// SwiftUI layout freezes (7-60s) during keyboard animation and scroll.
private struct FlatMarkdownView: View {
    let segments: [FlatSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let attributed):
                    Text(attributed)
                        .textSelection(.enabled)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                case .thematicBreak:
                    Rectangle()
                        .fill(Color.tokyoComment.opacity(0.4))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Segment types for the flat renderer.
///
/// Built once from `[MarkdownBlock]` via `build(from:)`, then cached in `@State`.
/// All AttributedString construction happens at build time (off main thread),
/// so the view body is a trivial switch over pre-computed values.
enum FlatSegment: Sendable {
    case text(AttributedString)
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case thematicBreak

    /// Collapse consecutive inline blocks into single AttributedString segments.
    /// Code blocks, tables, and thematic breaks remain as separate segments.
    static func build(from blocks: [MarkdownBlock]) -> [FlatSegment] {
        var result: [FlatSegment] = []
        var pendingText = AttributedString()

        func flushText() {
            guard !pendingText.characters.isEmpty else { return }
            result.append(.text(pendingText))
            pendingText = AttributedString()
        }

        for block in blocks {
            switch block {
            case .codeBlock(let language, let code):
                flushText()
                result.append(.codeBlock(language: language, code: code))
            case .table(let headers, let rows):
                flushText()
                result.append(.table(headers: headers, rows: rows))
            case .thematicBreak:
                flushText()
                result.append(.thematicBreak)
            default:
                if !pendingText.characters.isEmpty {
                    pendingText.append(AttributedString("\n\n"))
                }
                pendingText.append(Self.attributedString(for: block))
            }
        }

        flushText()
        return result
    }

    // MARK: - Block → AttributedString

    private static func attributedString(for block: MarkdownBlock) -> AttributedString {
        switch block {
        case .heading(let level, let inlines):
            var result = renderInlines(inlines)
            let font: Font = switch level {
            case 1: .title.bold()
            case 2: .title2.bold()
            case 3: .title3.bold()
            case 4: .headline
            case 5: .subheadline.bold()
            default: .subheadline
            }
            result.font = font
            result.foregroundColor = .tokyoFg
            return result

        case .paragraph(let inlines):
            var result = renderInlines(inlines)
            result.foregroundColor = .tokyoFg
            return result

        case .blockQuote(let children):
            var result = AttributedString("▎ ")
            result.foregroundColor = .tokyoPurple
            for (i, child) in children.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                result.append(attributedString(for: child))
            }
            result.foregroundColor = .tokyoFgDim
            return result

        case .unorderedList(let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var bullet = AttributedString("  • ")
                bullet.foregroundColor = .tokyoFgDim
                result.append(bullet)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n    ")) }
                    result.append(attributedString(for: block))
                }
            }
            return result

        case .orderedList(let start, let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var num = AttributedString("  \(start + i). ")
                num.foregroundColor = .tokyoFgDim
                result.append(num)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    result.append(attributedString(for: block))
                }
            }
            return result

        case .htmlBlock(let html):
            var result = AttributedString(html.trimmingCharacters(in: .whitespacesAndNewlines))
            result.font = .system(.caption, design: .monospaced)
            result.foregroundColor = .tokyoComment
            return result

        case .codeBlock, .table, .thematicBreak:
            return AttributedString()
        }
    }

    // MARK: - Inline → AttributedString

    private static func renderInlines(_ inlines: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(renderInline(inline))
        }
        return result
    }

    private static func renderInline(_ inline: MarkdownInline) -> AttributedString {
        switch inline {
        case .text(let string):
            return AttributedString(string)
        case .emphasis(let children):
            var result = renderInlines(children)
            result.inlinePresentationIntent = .emphasized
            return result
        case .strong(let children):
            var result = renderInlines(children)
            result.inlinePresentationIntent = .stronglyEmphasized
            return result
        case .code(let code):
            var result = AttributedString(code)
            result.font = .system(.body, design: .monospaced)
            result.foregroundColor = .tokyoCyan
            return result
        case .link(let children, _):
            var result = renderInlines(children)
            result.foregroundColor = .tokyoBlue
            result.underlineStyle = .single
            return result
        case .image(let alt, _):
            if alt.isEmpty { return AttributedString() }
            var result = AttributedString("[\(alt)]")
            result.foregroundColor = .tokyoComment
            return result
        case .softBreak:
            return AttributedString("\n")
        case .hardBreak:
            return AttributedString("\n")
        case .html(let raw):
            var result = AttributedString(raw)
            result.foregroundColor = .tokyoComment
            return result
        case .strikethrough(let children):
            var result = renderInlines(children)
            result.strikethroughStyle = .single
            return result
        }
    }
}

// MARK: - CommonMark View (Legacy — kept for reference)

/// Full CommonMark renderer using SwiftUI view tree.
///
/// **WARNING**: This causes layout freezes (7-60s) due to deep VStack + AnyView nesting.
/// Use `FlatMarkdownView` instead. Kept for reference and tests.
///
/// Renders the `[MarkdownBlock]` tree produced by `parseCommonMark(_:)`.
/// Supports all CommonMark block and inline elements plus GFM tables.
private struct CommonMarkView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: Block Rendering

    /// Renders a single block node.
    ///
    /// Returns `AnyView` to prevent Swift type-checker explosion from the
    /// 9-branch switch + recursive calls (blockQuote/list → blockView).
    private func blockView(_ block: MarkdownBlock) -> AnyView {
        switch block {
        case .heading(let level, let inlines):
            AnyView(headingView(level: level, inlines: inlines))
        case .paragraph(let inlines):
            AnyView(paragraphView(inlines))
        case .blockQuote(let children):
            AnyView(blockQuoteView(children))
        case .codeBlock(let language, let code):
            AnyView(CodeBlockView(language: language, code: code))
        case .unorderedList(let items):
            AnyView(unorderedListView(items))
        case .orderedList(let start, let items):
            AnyView(orderedListView(start: start, items: items))
        case .thematicBreak:
            AnyView(thematicBreakView())
        case .table(let headers, let rows):
            AnyView(TableBlockView(headers: headers, rows: rows))
        case .htmlBlock(let html):
            AnyView(htmlBlockView(html))
        }
    }

    // MARK: Heading

    private func headingView(level: Int, inlines: [MarkdownInline]) -> some View {
        renderInlines(inlines)
            .font(headingFont(level: level))
            .foregroundStyle(Color.tokyoFg)
            .textSelection(.enabled)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .subheadline
        }
    }

    // MARK: Paragraph

    private func paragraphView(_ inlines: [MarkdownInline]) -> some View {
        renderInlines(inlines)
            .foregroundStyle(Color.tokyoFg)
            .textSelection(.enabled)
    }

    // MARK: Block Quote

    private func blockQuoteView(_ children: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.tokyoPurple.opacity(0.6))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    blockView(child)
                }
            }
            .foregroundStyle(Color.tokyoFgDim)
        }
    }

    // MARK: Lists

    private func unorderedListView(_ items: [[MarkdownBlock]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, blocks in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(.tokyoFgDim)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                }
            }
        }
    }

    private func orderedListView(start: Int, items: [[MarkdownBlock]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(start + index).")
                        .foregroundStyle(.tokyoFgDim)
                        .frame(minWidth: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                }
            }
        }
    }

    // MARK: Thematic Break

    private func thematicBreakView() -> some View {
        Rectangle()
            .fill(Color.tokyoComment.opacity(0.4))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    // MARK: HTML Block

    private func htmlBlockView(_ html: String) -> some View {
        Text(html.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.tokyoComment)
    }

    // MARK: Inline Rendering

    /// Render inline nodes as a composed SwiftUI `Text` value.
    ///
    /// Uses `Text` concatenation (`+`) to preserve per-run styling
    /// (bold, italic, code, links) within a single text flow.
    private func renderInlines(_ inlines: [MarkdownInline]) -> Text {
        inlines.reduce(Text("")) { $0 + renderInline($1) }
    }

    private func renderInline(_ inline: MarkdownInline) -> Text {
        switch inline {
        case .text(let string):
            return Text(string)
        case .emphasis(let children):
            return renderInlines(children).italic()
        case .strong(let children):
            return renderInlines(children).bold()
        case .code(let code):
            return Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.tokyoCyan)
        case .link(let children, _):
            return renderInlines(children)
                .foregroundStyle(Color.tokyoBlue)
                .underline()
        case .image(let alt, _):
            if alt.isEmpty { return Text("") }
            return Text("[\(alt)]")
                .foregroundStyle(Color.tokyoComment)
        case .softBreak:
            return Text("\n")
        case .hardBreak:
            return Text("\n")
        case .html(let raw):
            return Text(raw)
                .foregroundStyle(Color.tokyoComment)
        case .strikethrough(let children):
            return renderInlines(children).strikethrough()
        }
    }
}

// MARK: - Code Block Views

/// Shared chrome for code block containers.
private struct CodeBlockChrome<Content: View>: View {
    let language: String?
    let code: String
    var onExpand: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language + expand + copy
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
                Spacer()
                if let onExpand {
                    Button {
                        onExpand()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tokyoFgDim)
                }
                Button {
                    UIPasteboard.general.string = code
                    isCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        isCopied = false
                    }
                } label: {
                    Label(
                        isCopied ? "Copied" : "Copy",
                        systemImage: isCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tokyoFgDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tokyoBgHighlight)

            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(12)
            }
        }
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Code block with async syntax highlighting.
///
/// Renders plain monospaced text immediately, then highlights asynchronously
/// via `Task.detached`. Prevents main-thread stalls when multiple code blocks
/// finalize simultaneously.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var highlighted: AttributedString?
    @State private var showFullScreen = false

    var body: some View {
        CodeBlockChrome(language: language, code: code, onExpand: { showFullScreen = true }) {
            if let highlighted {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tokyoFg)
                    .textSelection(.enabled)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .code(
                content: code, language: language, filePath: nil, startLine: 1
            ))
        }
        .task(id: codeIdentity) {
            let lang = language.map { SyntaxLanguage.detect($0) } ?? .unknown
            guard lang != .unknown else { return }
            let result = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(code, language: lang)
            }.value
            highlighted = result
        }
    }

    private var codeIdentity: String {
        "\(language ?? "")\(code.count)"
    }
}

/// Streaming code block — plain monospaced text, no syntax highlighting.
private struct StreamingCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        CodeBlockChrome(language: language, code: code) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tokyoFg)
        }
    }
}

// MARK: - Table Block View

/// Compact, horizontally-scrollable markdown table.
///
/// Uses SwiftUI `Grid` so columns align across header and data rows.
struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // Header row
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoCyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .gridColumnAlignment(.leading)
                    }
                }
                .background(Color.tokyoBgHighlight)

                // Separator
                Rectangle()
                    .fill(Color.tokyoComment.opacity(0.35))
                    .frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tokyoFg)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                    }

                    if rowIdx < rows.count - 1 {
                        Rectangle()
                            .fill(Color.tokyoComment.opacity(0.15))
                            .frame(height: 1)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Streaming Code Block Parser

enum ContentBlock: Equatable {
    case markdown(String)
    /// - `isComplete`: `true` when the closing ``` was found; `false` for an
    ///   unclosed (still-streaming) block.
    case codeBlock(language: String?, code: String, isComplete: Bool)
    /// Markdown table — rendered compact and horizontally scrollable.
    case table(headers: [String], rows: [[String]])
}

/// Split markdown content into alternating prose, fenced code blocks, and tables.
///
/// Used only during streaming. For finalized content, `parseCommonMark(_:)`
/// provides full CommonMark support via apple/swift-markdown.
func parseCodeBlocks(_ content: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    var current = ""
    var inCodeBlock = false
    var codeLanguage: String?
    var codeContent = ""
    var tableLines: [Substring] = []

    func flushProse() {
        guard !current.isEmpty else { return }
        blocks.append(.markdown(current))
        current = ""
    }

    func flushTable() {
        guard tableLines.count >= 2 else {
            for line in tableLines {
                if !current.isEmpty { current += "\n" }
                current += line
            }
            tableLines.removeAll()
            return
        }

        let sepLine = tableLines[1]
        let isSeparator = sepLine.contains("-") && sepLine.split(separator: "|").allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" }
        }
        guard isSeparator else {
            for line in tableLines {
                if !current.isEmpty { current += "\n" }
                current += line
            }
            tableLines.removeAll()
            return
        }

        flushProse()

        let headers = parseTableRow(tableLines[0])
        var rows: [[String]] = []
        for line in tableLines.dropFirst(2) {
            rows.append(parseTableRow(line))
        }
        blocks.append(.table(headers: headers, rows: rows))
        tableLines.removeAll()
    }

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inCodeBlock && line.hasPrefix("```") {
            flushTable()
            flushProse()
            inCodeBlock = true
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLanguage = lang.isEmpty ? nil : lang
            codeContent = ""
        } else if inCodeBlock && line.hasPrefix("```") {
            blocks.append(.codeBlock(language: codeLanguage, code: codeContent, isComplete: true))
            inCodeBlock = false
            codeLanguage = nil
            codeContent = ""
        } else if inCodeBlock {
            if !codeContent.isEmpty { codeContent += "\n" }
            codeContent += line
        } else if isTableLine(line) {
            if tableLines.isEmpty {
                flushProse()
            }
            tableLines.append(line)
        } else {
            if !tableLines.isEmpty {
                flushTable()
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
    }

    if inCodeBlock {
        flushTable()
        blocks.append(.codeBlock(language: codeLanguage, code: codeContent, isComplete: false))
    } else {
        flushTable()
        if !current.isEmpty {
            blocks.append(.markdown(current))
        }
    }

    return blocks
}

private func isTableLine(_ line: Substring) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1
}

private func parseTableRow(_ line: Substring) -> [String] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let inner = trimmed.dropFirst().dropLast()
    return inner.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}
