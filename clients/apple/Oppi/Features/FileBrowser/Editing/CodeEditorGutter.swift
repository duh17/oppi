import UIKit

/// The paragraphs TextKit laid out for the viewport, reduced to what the gutter
/// needs. The gutter reads rows from here and never lays out text itself: a
/// point lookup or `.ensuresLayout` at draw time lays out against estimated
/// heights, and TextKit then replaces them and re-anchors the viewport under a
/// number it already drew. The text view rebuilds this whenever the viewport
/// has been laid out.
///
/// All y values are in the text view's content coordinates.
struct CodeEditorGutterSnapshot {
    struct Paragraph {
        /// Zero-based logical line.
        let line: Int
        let minY: CGFloat
        let maxY: CGFloat
        /// Baseline and bottom of the paragraph's first row.
        let firstBaseline: CGFloat
        let firstRowBottom: CGFloat
        /// Kept to find a later row when the first one is scrolled off.
        let fragment: NSTextLayoutFragment
    }

    /// The empty line after a trailing line break: it has no layout fragment,
    /// so it sits where the last paragraph ends.
    struct TrailingLine {
        let line: Int
        let minY: CGFloat
        let baseline: CGFloat
    }

    /// One number to draw.
    struct Number: Equatable {
        let line: Int
        /// Baseline of the row it labels.
        let baseline: CGFloat
        /// The paragraph's first row is above the visible top, so the number
        /// sits at the first row still on screen.
        let isPinned: Bool
    }

    var paragraphs: [Paragraph] = []
    var trailingLine: TrailingLine?

    static var empty: CodeEditorGutterSnapshot { CodeEditorGutterSnapshot() }

    private init() {}

    /// Reads the viewport's laid-out paragraphs. Never asks TextKit to lay
    /// anything out.
    @MainActor
    init(capturing textView: CodeEditorTextView) {
        let font = textView.font ?? AppFont.monoEditor
        let insetTop = textView.textContainerInset.top
        guard textView.textStorage.length > 0 else {
            trailingLine = TrailingLine(line: 0, minY: insetTop, baseline: insetTop + font.ascender)
            return
        }
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let index = textView.lineIndex
        let documentStart = content.documentRange.location
        var lastEnd = 0
        var lastMaxY: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending { return false }
            let frame = fragment.layoutFragmentFrame
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let first = fragment.textLineFragments.first
            let rowTop = frame.minY + insetTop + (first?.typographicBounds.minY ?? 0)
            paragraphs.append(Paragraph(
                line: index.line(containing: offset),
                minY: frame.minY + insetTop,
                maxY: frame.maxY + insetTop,
                firstBaseline: rowTop + (first?.glyphOrigin.y ?? font.ascender),
                firstRowBottom: rowTop + (first?.typographicBounds.height ?? frame.height),
                fragment: fragment
            ))
            lastEnd = content.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
            lastMaxY = frame.maxY + insetTop
            return true
        }
        if let last = paragraphs.last, lastEnd == textView.textStorage.length,
           index.starts[index.lineCount - 1] == lastEnd, last.line + 1 == index.lineCount - 1 {
            trailingLine = TrailingLine(line: last.line + 1, minY: lastMaxY, baseline: lastMaxY + font.ascender)
        }
    }

    /// The numbers to draw for the visible band `visibleTop..<visibleBottom`.
    /// A paragraph whose first row is above the band keeps its number at the
    /// first of its rows that is still on screen, so a tall wrapped paragraph
    /// never leaves the gutter empty.
    func numbers(visibleTop: CGFloat, visibleBottom: CGFloat, rowHeight: CGFloat) -> [Number] {
        var result: [Number] = []
        let threshold = visibleTop + rowHeight / 2
        for paragraph in paragraphs where paragraph.maxY > visibleTop && paragraph.minY < visibleBottom {
            if paragraph.firstRowBottom > threshold {
                result.append(Number(line: paragraph.line, baseline: paragraph.firstBaseline, isPinned: false))
            } else if let row = paragraph.fragment.textLineFragment(forVerticalOffset: threshold - paragraph.minY, requiresExactMatch: false) {
                let baseline = paragraph.minY + row.typographicBounds.minY + row.glyphOrigin.y
                result.append(Number(line: paragraph.line, baseline: baseline, isPinned: true))
            }
        }
        if let trailingLine, trailingLine.minY + rowHeight > visibleTop, trailingLine.minY < visibleBottom {
            result.append(Number(line: trailingLine.line, baseline: trailingLine.baseline, isPinned: false))
        }
        return result
    }
}

/// Line numbers for the rows on screen, drawn each time the text view has
/// laid out its viewport, scrolled, or changed text. The view is pinned to the
/// viewport by its text view.
final class CodeEditorGutterView: UIView {
    weak var textView: CodeEditorTextView?
    var codeFont = AppFont.monoEditor {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func numberFont(for codeFont: UIFont) -> UIFont {
        .monospacedDigitSystemFont(ofSize: max(10, codeFont.pointSize * 0.8), weight: .regular)
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let chrome = textView.chrome
        chrome.gutterBackground.setFill()
        UIRectFill(bounds)
        chrome.divider.setFill()
        UIRectFill(CGRect(x: bounds.width - 1 / max(1, traitCollection.displayScale), y: 0, width: 1 / max(1, traitCollection.displayScale), height: bounds.height))

        let numberFont = Self.numberFont(for: codeFont)
        let currentLine = textView.selectedRange.length == 0 ? textView.caretLineAndColumn.line : -1
        let right = bounds.width - 10
        for number in textView.gutterNumbers {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: number.line == currentLine ? chrome.currentNumber : chrome.number,
            ]
            let text = String(number.line + 1) as NSString
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: right - width, y: number.baseline - frame.minY - numberFont.ascender), withAttributes: attributes)
        }
    }
}
