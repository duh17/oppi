import UIKit

/// Paints `CodeEditorHighlightEngine` spans into the editor's text storage.
///
/// Only the rows around the viewport are painted. An edit bumps a generation
/// and schedules one pass after a short pause (longer for big files); results
/// for an older generation are dropped. Scrolling past the painted window
/// paints the new rows. Attribute edits never touch characters, selection, or
/// undo, and wait while marked (IME) text is open.
///
/// It also owns paragraph styles (where a wrapped row starts, see
/// `CodeEditorWrapIndent`). Those do not depend on Syntax Highlighting: they
/// are set for the whole buffer when it is restyled, then kept current around
/// the viewport after edits and as the viewport moves, whether or not colors
/// are painted.
@MainActor
final class CodeEditorHighlighter {
    struct Style {
        var font: UIFont
        var boldFont: UIFont
        var italicFont: UIFont
        var foreground: UIColor
        var tokens: [SyntaxTokenKind: UIColor]
        var heading: UIColor
        var link: UIColor
        var url: UIColor
        var code: UIColor
        var quote: UIColor
        var marker: UIColor
        /// Columns per tab stop, and the width of one column.
        var tabWidth: Int
        var columnWidth: CGFloat

        var base: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraphStyle(wrapColumns: 0)]
        }

        /// Tab stops every `tabWidth` columns; wrapped rows start `wrapColumns`
        /// columns in, where the line's text starts.
        func paragraphStyle(wrapColumns: Int) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.defaultTabInterval = CGFloat(tabWidth) * columnWidth
            style.tabStops = []
            style.headIndent = CGFloat(wrapColumns) * columnWidth
            return style
        }

        @MainActor
        static func make(themeID: ThemeID, font: UIFont, tabWidth: Int) -> Style {
            let palette = themeID.palette
            func traits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
                font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            }
            var tokens: [SyntaxTokenKind: UIColor] = [:]
            for kind in [SyntaxTokenKind.comment, .keyword, .string, .number, .type, .punctuation, .function, .operator] {
                tokens[kind] = SyntaxHighlighter.color(for: kind, themeID: themeID)
            }
            return Style(
                font: font,
                boldFont: traits(.traitBold),
                italicFont: traits(.traitItalic),
                foreground: UIColor(palette.fg),
                tokens: tokens,
                heading: UIColor(palette.mdHeading),
                link: UIColor(palette.mdLink),
                url: UIColor(palette.mdLinkUrl),
                code: UIColor(palette.mdCode),
                quote: UIColor(palette.mdQuote),
                marker: UIColor(palette.comment),
                tabWidth: tabWidth,
                columnWidth: ("M" as NSString).size(withAttributes: [.font: font]).width
            )
        }

        func attributes(for style: CodeEditorSpanStyle) -> [NSAttributedString.Key: Any] {
            switch style {
            case .token(let kind): tokens[kind].map { [.foregroundColor: $0] } ?? [:]
            case .heading: [.foregroundColor: heading, .font: boldFont]
            case .strong: [.font: boldFont]
            case .emphasis: [.font: italicFont]
            case .strikethrough: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: marker]
            case .inlineCode: [.foregroundColor: code]
            case .link: [.foregroundColor: link]
            case .url: [.foregroundColor: url, .underlineStyle: NSUnderlineStyle.single.rawValue]
            case .quote: [.foregroundColor: quote, .font: italicFont]
            case .marker: [.foregroundColor: marker]
            }
        }
    }

    let engine: CodeEditorHighlightEngine
    private let isMarkdown: Bool
    private weak var textView: CodeEditorTextView?
    private var style: Style
    private var generation = 0
    private var paintedGeneration = -1
    private var paintedWindow = NSRange(location: 0, length: 0)
    /// With colors off: the generation and range whose paragraph styles are
    /// known current. An edit outside the range (Replace All) leaves lines
    /// there stale until the viewport reaches them.
    private var styledGeneration = -1
    private var styledWindow = NSRange(location: 0, length: 0)
    private var scheduled: Task<Void, Never>?
    private var running = false
    /// A pass was asked for while one was parsing; run again when it ends.
    private var rerun = false

    /// Width of the wrapped text area in points; nil when lines do not wrap.
    /// Wrapped rows never start deeper than half of it, so a deeply indented
    /// line still has room for text.
    var wrapWidth: CGFloat? {
        didSet {
            guard wrapCap(for: oldValue) != wrapCap(for: wrapWidth), let textView else { return }
            let storage = textView.textStorage
            applyParagraphStyles(in: NSRange(location: 0, length: storage.length), storage: storage)
        }
    }

    private func wrapCap(for width: CGFloat?) -> Int {
        guard let width, style.columnWidth > 0 else { return .max }
        return max(2, Int(width / style.columnWidth) / 2)
    }

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            restyle(style)
        }
    }

    init(textView: CodeEditorTextView, grammar: CodeEditorHighlightEngine.Grammar, style: Style, isEnabled: Bool) {
        self.textView = textView
        self.engine = CodeEditorHighlightEngine(grammar: grammar)
        self.isMarkdown = grammar == .markdown
        self.style = style
        self.isEnabled = isEnabled
    }

    deinit {
        scheduled?.cancel()
    }

    /// Theme or font changed: reset every run to the base style, then repaint.
    func restyle(_ style: Style) {
        self.style = style
        paragraphStyles = [:]
        // New text (Use Disk Version) or new colors: a pass already parsing
        // must not paint its now-stale spans.
        generation += 1
        guard let textView else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        let everything = NSRange(location: 0, length: storage.length)
        storage.setAttributes(style.base, range: everything)
        applyParagraphStyles(in: everything, storage: storage)
        storage.endEditing()
        styledGeneration = generation
        styledWindow = everything
        textView.typingAttributes = style.base
        paintedGeneration = -1
        schedule(after: .zero)
    }

    func textDidChange() {
        generation += 1
        let large = (textView?.textStorage.length ?? 0) > 200_000
        schedule(after: .milliseconds(large ? 120 : 40))
    }

    func viewportDidChange() {
        guard let window = currentWindow() else { return }
        guard isEnabled else {
            if styledGeneration != generation || NSIntersectionRange(window, styledWindow) != window { styleParagraphs(in: window) }
            return
        }
        if paintedGeneration == generation, NSIntersectionRange(window, paintedWindow) == window { return }
        if scheduled == nil { schedule(after: .zero) }
    }

    private func schedule(after delay: Duration) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.pass()
        }
    }

    private func pass() async {
        scheduled = nil
        guard let textView else { return }
        guard isEnabled else {
            // No colors, but a line edited since the last pass may need a new wrap indent.
            if textView.markedTextRange != nil {
                schedule(after: .milliseconds(200))
            } else if let window = currentWindow() {
                styleParagraphs(in: window)
            }
            return
        }
        if running {
            rerun = true
            return
        }
        if textView.markedTextRange != nil {
            schedule(after: .milliseconds(200))
            return
        }
        guard let window = currentWindow() else { return }
        running = true
        let target = generation
        // `string` bridges to an immutable copy the engine can read off the main thread.
        let snapshot = textView.textStorage.string
        let spans = await engine.spans(text: snapshot, window: window)
        running = false
        guard let textView = self.textView else { return }
        if target == generation, textView.markedTextRange == nil {
            paint(spans, in: window, storage: textView.textStorage)
            paintedGeneration = target
            paintedWindow = window
        }
        if rerun || target != generation || textView.markedTextRange != nil {
            // Typed or scrolled while we parsed: one more pass for the newest text.
            rerun = false
            if scheduled == nil { schedule(after: .milliseconds(40)) }
        } else {
            // The view may have scrolled while we parsed.
            viewportDidChange()
        }
    }

    private func paint(_ spans: [CodeEditorSpan], in window: NSRange, storage: NSTextStorage) {
        let window = NSIntersectionRange(window, NSRange(location: 0, length: storage.length))
        guard window.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(style.base, range: window)
        applyParagraphStyles(in: window, storage: storage)
        for span in spans {
            let range = NSIntersectionRange(span.range, window)
            guard range.length > 0 else { continue }
            let attributes = style.attributes(for: span.style)
            if !attributes.isEmpty { storage.addAttributes(attributes, range: range) }
        }
        storage.endEditing()
    }

    private var paragraphStyles: [Int: NSParagraphStyle] = [:]

    /// Colors off: brings the paragraph styles around the viewport up to date.
    private func styleParagraphs(in window: NSRange) {
        guard let textView, textView.markedTextRange == nil else { return }
        applyParagraphStyles(in: window, storage: textView.textStorage)
        styledGeneration = generation
        styledWindow = window
    }

    /// Gives every line in `range` the paragraph style for its wrap indent,
    /// touching only lines whose style differs.
    private func applyParagraphStyles(in range: NSRange, storage: NSTextStorage) {
        let text = storage.mutableString
        let end = NSMaxRange(range)
        let cap = wrapCap(for: wrapWidth)
        var location = range.location
        storage.beginEditing()
        while location < end {
            var next = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &next, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let columns = min(cap, CodeEditorWrapIndent.columns(
                in: text, lineStart: location, contentsEnd: contentsEnd, tabWidth: style.tabWidth, markdown: isMarkdown
            ))
            let wanted = paragraphStyles[columns] ?? style.paragraphStyle(wrapColumns: columns)
            paragraphStyles[columns] = wanted
            let current = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            if current?.isEqual(wanted) != true {
                storage.addAttribute(.paragraphStyle, value: wanted, range: NSRange(location: location, length: next - location))
            }
            guard next > location else { break }
            location = next
        }
        storage.endEditing()
    }

    /// Lines around the viewport: a screen of rows above and below it.
    private func currentWindow() -> NSRange? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let length = textView.textStorage.length
        guard length > 0 else { return nil }
        let text = textView.textStorage.mutableString
        var visible = NSRange(location: 0, length: min(length, 8_000))
        if let viewport = layout.textViewportLayoutController.viewportRange {
            let start = content.offset(from: content.documentRange.location, to: viewport.location)
            let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            if start >= 0, end >= start { visible = NSRange(location: start, length: end - start) }
        }
        let margin = max(4_000, visible.length)
        let start = max(0, visible.location - margin)
        let end = min(length, NSMaxRange(visible) + margin)
        return text.lineRange(for: NSRange(location: start, length: end - start))
    }
}
