// swiftlint:disable file_length
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

    func get(_ content: String, themeID: ThemeID = ThemeRuntimeState.currentThemeID()) -> [FlatSegment]? {
        guard shouldCache(content) else { return nil }
        let key = stableKey(for: content, themeID: themeID)
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
        segments: [FlatSegment]
    ) {
        let sourceBytes = content.utf8.count
        guard sourceBytes <= maxEntrySourceBytes else { return }

        let key = stableKey(for: content, themeID: themeID)
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

    private func stableKey(for content: String, themeID: ThemeID) -> UInt64 {
        // FNV-1a 64-bit hash (stable across process launches).
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in themeID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        // Separator to avoid accidental collisions between
        // `(themeA + contentB)` and `(themeAB + content)` byte streams.
        hash ^= 0xFF
        hash &*= 1_099_511_628_211

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
    @State private var cachedThemeID: ThemeID?

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
        let themeID = ThemeRuntimeState.currentThemeID()

        if content.count > Self.plainTextFallbackThreshold {
            Text(content)
                .foregroundStyle(.themeFg)
        } else if let segments = cachedSegments, cachedThemeID == themeID {
            FlatMarkdownView(segments: segments, themeID: themeID)
        } else if let cached = synchronousCacheLookup(themeID: themeID) {
            // Synchronous cache hit — render immediately without placeholder.
            // Critical for LazyVStack: avoids placeholder → content height
            // mismatch that triggers cascading re-layouts when recycled
            // views get their @State reset to nil on off-screen destruction.
            FlatMarkdownView(segments: cached, themeID: themeID)
                .onAppear {
                    cachedSegments = cached
                    cachedThemeID = themeID
                }
        } else {
            // Cold start: no cache hit. Show placeholder and parse async.
            Color.clear
                .frame(height: placeholderHeight)
                .task(id: parseTaskID(themeID: themeID)) {
                    let text = content
                    let shouldUseCache = MarkdownSegmentCache.shared.shouldCache(text)

                    // Double-check cache (might have been warmed while waiting)
                    if shouldUseCache,
                       let cached = MarkdownSegmentCache.shared.get(text, themeID: themeID) {
                        cachedSegments = cached
                        cachedThemeID = themeID
                        return
                    }

                    let segments = await Task.detached {
                        let blocks = parseCommonMark(text)
                        return FlatSegment.build(from: blocks, themeID: themeID)
                    }.value

                    guard !Task.isCancelled else { return }

                    if shouldUseCache {
                        MarkdownSegmentCache.shared.set(text, themeID: themeID, segments: segments)
                    }
                    cachedSegments = segments
                    cachedThemeID = themeID
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
    private func synchronousCacheLookup(themeID: ThemeID) -> [FlatSegment]? {
        guard MarkdownSegmentCache.shared.shouldCache(content) else { return nil }
        return MarkdownSegmentCache.shared.get(content, themeID: themeID)
    }

    private func parseTaskID(themeID: ThemeID) -> Int {
        var hasher = Hasher()
        hasher.combine(themeID.rawValue)
        hasher.combine(content)
        return hasher.finalize()
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
                        .foregroundStyle(.themeFg)

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
/// is rendered as selectable attributed UITextView-backed rows.
/// Only code blocks and tables get dedicated sub-views.
///
/// This avoids the deep VStack + AnyView tree of `CommonMarkView` that caused
/// SwiftUI layout freezes (7-60s) during keyboard animation and scroll.
private struct FlatMarkdownView: View {
    let segments: [FlatSegment]
    let themeID: ThemeID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let attributed):
                    SelectableAttributedText(attributed: attributed, themeID: themeID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                case .thematicBreak:
                    Rectangle()
                        .fill(Color.themeComment.opacity(0.4))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct SelectableAttributedText: UIViewRepresentable {
    let attributed: AttributedString
    let themeID: ThemeID

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastAttributed: AttributedString?
        var lastThemeID: ThemeID?
        var lastContentSizeCategory: UIContentSizeCategory?

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content else {
                return defaultAction
            }

            return shouldOpenLinkExternally(url) ? defaultAction : nil
        }

        @MainActor
        private func shouldOpenLinkExternally(_ url: URL) -> Bool {
            let normalizedURL = normalizedInteractionURL(url)

            guard let scheme = normalizedURL.scheme?.lowercased(), scheme == "pi" || scheme == "oppi" else {
                return true
            }

            NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            return false
        }

        private func normalizedInteractionURL(_ url: URL) -> URL {
            let normalized = normalizedURLString(url.absoluteString)
            return URL(string: normalized) ?? url
        }

        private func normalizedURLString(_ raw: String) -> String {
            let delimiters: Set<Character> = ["`", "'", "\"", "’", "”"]
            let encodedDelimiters = ["%60", "%27", "%22"]

            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            while !value.isEmpty {
                if let suffix = encodedDelimiters.first(where: { value.lowercased().hasSuffix($0) }) {
                    value = String(value.dropLast(suffix.count))
                    continue
                }

                guard let last = value.last, delimiters.contains(last) else {
                    break
                }

                value.removeLast()
            }

            return value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.textDragInteraction?.isEnabled = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let contentSizeCategory = textView.traitCollection.preferredContentSizeCategory
        if context.coordinator.lastThemeID == themeID,
           context.coordinator.lastContentSizeCategory == contentSizeCategory,
           context.coordinator.lastAttributed == attributed {
            return
        }

        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let palette = themeID.palette
        let baseColor = UIColor(palette.fg)
        let linkColor = UIColor(palette.blue)

        textView.font = baseFont
        textView.textColor = baseColor
        textView.tintColor = linkColor
        textView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.attributedText = Self.normalizedAttributedText(
            from: attributed,
            baseFont: baseFont,
            baseColor: baseColor
        )

        context.coordinator.lastThemeID = themeID
        context.coordinator.lastContentSizeCategory = contentSizeCategory
        context.coordinator.lastAttributed = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitting.height)
    }

    private static func normalizedAttributedText(
        from attributed: AttributedString,
        baseFont: UIFont,
        baseColor: UIColor
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        let baseLuminance = perceivedLuminance(of: baseColor)
        let shouldCorrectDarkFallbackText = baseLuminance > 0.55

        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var updates: [NSAttributedString.Key: Any] = [:]

            if attributes[.font] == nil {
                updates[.font] = baseFont
            }

            if let color = attributes[.foregroundColor] as? UIColor {
                if shouldCorrectDarkFallbackText && perceivedLuminance(of: color) < 0.2 {
                    updates[.foregroundColor] = baseColor
                }
            } else {
                updates[.foregroundColor] = baseColor
            }

            if !updates.isEmpty {
                mutable.addAttributes(updates, range: range)
            }
        }

        return mutable
    }

    private static func perceivedLuminance(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            var white: CGFloat = 0
            guard color.getWhite(&white, alpha: &alpha) else { return 0 }
            return white
        }

        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
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

    /// Convert CommonMark blocks into renderable segments.
    ///
    /// Adjacent text-like blocks are merged into a single `.text` segment so
    /// native selection can cross paragraph/list/heading boundaries.
    /// Code blocks and tables remain standalone segments.
    static func build(
        from blocks: [MarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> [Self] {
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
                pendingText.append(AttributedString("\n\n"))
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

            default:
                let attributed = Self.attributedString(for: block, themeID: themeID)
                appendTextBlock(attributed)
            }
        }

        flushPendingText()
        return result
    }

    // MARK: - Block → AttributedString

    private static func attributedString(for block: MarkdownBlock, themeID: ThemeID) -> AttributedString {
        let palette = themeID.palette

        switch block {
        case .heading(let level, let inlines):
            var result = renderInlines(inlines, themeID: themeID)
            let font: Font = switch level {
            case 1: .title.bold()
            case 2: .title2.bold()
            case 3: .title3.bold()
            case 4: .headline
            case 5: .subheadline.bold()
            default: .subheadline
            }
            result.font = font
            result.foregroundColor = palette.fg
            return result

        case .paragraph(let inlines):
            var result = renderInlines(inlines, themeID: themeID)
            result.foregroundColor = palette.fg
            return result

        case .blockQuote(let children):
            var result = AttributedString("▎ ")
            result.foregroundColor = palette.purple
            for (i, child) in children.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                result.append(attributedString(for: child, themeID: themeID))
            }
            result.foregroundColor = palette.fgDim
            return result

        case .unorderedList(let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var bullet = AttributedString("  • ")
                bullet.foregroundColor = palette.fgDim
                result.append(bullet)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n    ")) }
                    result.append(attributedString(for: block, themeID: themeID))
                }
            }
            return result

        case .orderedList(let start, let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var num = AttributedString("  \(start + i). ")
                num.foregroundColor = palette.fgDim
                result.append(num)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    result.append(attributedString(for: block, themeID: themeID))
                }
            }
            return result

        case .htmlBlock(let html):
            var result = AttributedString(html.trimmingCharacters(in: .whitespacesAndNewlines))
            result.font = .system(.caption, design: .monospaced)
            result.foregroundColor = palette.comment
            return result

        case .codeBlock, .table, .thematicBreak:
            return AttributedString()
        }
    }

    // MARK: - Inline → AttributedString

    private static func renderInlines(_ inlines: [MarkdownInline], themeID: ThemeID) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(renderInline(inline, themeID: themeID))
        }
        return result
    }

    private static func renderInline(_ inline: MarkdownInline, themeID: ThemeID) -> AttributedString {
        let palette = themeID.palette

        switch inline {
        case .text(let string):
            return AttributedString(string)
        case .emphasis(let children):
            var result = renderInlines(children, themeID: themeID)
            result.inlinePresentationIntent = .emphasized
            return result
        case .strong(let children):
            var result = renderInlines(children, themeID: themeID)
            result.inlinePresentationIntent = .stronglyEmphasized
            return result
        case .code(let code):
            var result = AttributedString(code)
            result.font = .system(.body, design: .monospaced)
            result.foregroundColor = palette.cyan
            return result
        case .link(let children, let destination):
            var result = renderInlines(children, themeID: themeID)
            result.foregroundColor = palette.blue
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
            result.foregroundColor = palette.comment
            return result
        case .softBreak:
            return AttributedString("\n")
        case .hardBreak:
            return AttributedString("\n")
        case .html(let raw):
            var result = AttributedString(raw)
            result.foregroundColor = palette.comment
            return result
        case .strikethrough(let children):
            var result = renderInlines(children, themeID: themeID)
            result.strikethroughStyle = .single
            return result
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
                    .foregroundStyle(.themeMdCodeBlockBorder)
                Spacer()
                if let onExpand {
                    Button {
                        onExpand()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.themeFgDim)
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
                .foregroundStyle(.themeFgDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.themeBgHighlight)

            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(12)
            }
        }
        .background(Color.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.themeMdCodeBlockBorder.opacity(0.35), lineWidth: 1)
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
        CodeBlockChrome(
            language: language,
            code: code,
            onExpand: { showFullScreen = true },
            content: {
                if let highlighted {
                    Text(highlighted)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.themeFg)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        )
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
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Table Block View

/// SwiftUI wrapper around `NativeTableBlockView` (UIKit).
///
/// Single table implementation used everywhere — streaming, finalized, and
/// assistant markdown content. Horizontal scroll + monospaced column alignment
/// with proper emoji/CJK width handling.
struct TableBlockView: UIViewRepresentable {
    let headers: [String]
    let rows: [[String]]

    func makeUIView(context: Context) -> NativeTableBlockView {
        let view = NativeTableBlockView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: NativeTableBlockView, context: Context) {
        let palette = ThemeRuntimeState.currentThemeID().palette
        uiView.apply(headers: headers, rows: rows, palette: palette)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeTableBlockView, context: Context) -> CGSize? {
        let fallbackWidth = uiView.window?.windowScene?.screen.bounds.width ?? uiView.bounds.width
        let width = proposal.width ?? fallbackWidth
        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fitting.height)
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
