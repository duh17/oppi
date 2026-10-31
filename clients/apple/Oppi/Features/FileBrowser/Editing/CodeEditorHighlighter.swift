import UIKit

/// Paints `CodeEditorHighlightEngine` spans into the editor's text storage.
///
/// Only the rows around the viewport are painted. An edit bumps a generation
/// and schedules one pass after a short pause (longer for big files); results
/// for an older generation are dropped. Scrolling past the painted window
/// paints the new rows. Attribute edits never touch characters, selection, or
/// undo, and wait while marked (IME) text is open.
///
/// Where a wrapped row starts is not decided here: the storage holds one
/// default paragraph style for the buffer, and `CodeEditorParagraphStyler`
/// gives a paragraph that needs a hang its own as TextKit builds it.
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
            [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: CodeEditorParagraphStyler.paragraphStyle(columns: 0, tabWidth: tabWidth, columnWidth: columnWidth),
            ]
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
                foreground: palette.ui.fg,
                tokens: tokens,
                heading: palette.ui.mdHeading,
                link: palette.ui.mdLink,
                url: palette.ui.mdLinkUrl,
                code: palette.ui.mdCode,
                quote: palette.ui.mdQuote,
                marker: palette.ui.comment,
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
    private weak var textView: CodeEditorTextView?
    private var style: Style
    private var generation = 0
    private var paintedGeneration = -1
    private var paintedWindow = NSRange(location: 0, length: 0)
    private var scheduled: Task<Void, Never>?
    private var running = false
    /// A pass was asked for while one was parsing; run again when it ends.
    private var rerun = false

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            restyle(style)
        }
    }

    init(textView: CodeEditorTextView, grammar: CodeEditorHighlightEngine.Grammar, style: Style, isEnabled: Bool) {
        self.textView = textView
        self.engine = CodeEditorHighlightEngine(grammar: grammar)
        self.style = style
        self.isEnabled = isEnabled
    }

    deinit {
        scheduled?.cancel()
    }

    /// Theme or font changed: reset every run to the base style, then repaint.
    func restyle(_ style: Style) {
        self.style = style
        // New text (Use Disk Version) or new colors: a pass already parsing
        // must not paint its now-stale spans.
        generation += 1
        guard let textView else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        let everything = NSRange(location: 0, length: storage.length)
        storage.setAttributes(style.base, range: everything)
        storage.endEditing()
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
        guard isEnabled, let visible = viewportRange(), let window = window(around: visible) else { return }
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
        guard isEnabled, let textView else { return }
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
        for span in spans {
            let range = NSIntersectionRange(span.range, window)
            guard range.length > 0 else { continue }
            let attributes = style.attributes(for: span.style)
            if !attributes.isEmpty { storage.addAttributes(attributes, range: range) }
        }
        storage.endEditing()
    }

    /// What TextKit has laid out: the visible rows plus its overdraw.
    private func viewportRange() -> NSRange? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let length = textView.textStorage.length
        guard length > 0 else { return nil }
        if let viewport = layout.textViewportLayoutController.viewportRange {
            let start = content.offset(from: content.documentRange.location, to: viewport.location)
            let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            if start >= 0, end >= start { return NSRange(location: start, length: end - start) }
        }
        return NSRange(location: 0, length: min(length, 8_000))
    }

    private func currentWindow() -> NSRange? {
        viewportRange().flatMap { window(around: $0) }
    }

    /// Lines around the viewport: a screen of rows above and below it.
    private func window(around visible: NSRange) -> NSRange? {
        guard let textView else { return nil }
        let length = textView.textStorage.length
        let text = textView.textStorage.mutableString
        let margin = max(4_000, visible.length)
        let start = max(0, visible.location - margin)
        let end = min(length, NSMaxRange(visible) + margin)
        return text.lineRange(for: NSRange(location: start, length: end - start))
    }
}
