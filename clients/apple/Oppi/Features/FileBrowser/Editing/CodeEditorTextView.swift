import UIKit

/// Where typed input and editor key commands go before `UITextView` sees them.
@MainActor
protocol CodeEditorTextViewInputHandler: AnyObject {
    /// True when the handler consumed `text` (Vim command, auto-indent, pair).
    func codeEditor(_ textView: CodeEditorTextView, handleInsert text: String) -> Bool
    /// True when the handler consumed Backspace.
    func codeEditorHandleDeleteBackward(_ textView: CodeEditorTextView) -> Bool
    /// Key commands for the current mode, added to the text view's own.
    func codeEditorKeyCommands(_ textView: CodeEditorTextView) -> [UIKeyCommand]
    func codeEditor(_ textView: CodeEditorTextView, perform command: String)
}

/// The workspace editor's text view: one TextKit 2 `UITextView` with a line
/// number gutter, a current-line band, and a block caret for Vim's Normal mode.
///
/// The gutter and band are subviews that follow the viewport; they never touch
/// text storage, selection, or undo. Never read `layoutManager` here: it would
/// drop the view back to TextKit 1.
final class CodeEditorTextView: UITextView {
    weak var inputHandler: CodeEditorTextViewInputHandler?

    struct Chrome {
        var gutterBackground = UIColor.black
        var number = UIColor.gray
        var currentNumber = UIColor.white
        var currentLine = UIColor.white.withAlphaComponent(0.05)
        var divider = UIColor.white.withAlphaComponent(0.08)
        var blockCursor = UIColor.systemBlue.withAlphaComponent(0.55)
    }

    var chrome = Chrome() {
        didSet {
            gutter.backgroundColor = chrome.gutterBackground
            currentLineBand.backgroundColor = chrome.currentLine
            blockCursor.backgroundColor = chrome.blockCursor
            gutter.setNeedsDisplay()
        }
    }

    var showsLineNumbers = true {
        didSet {
            guard oldValue != showsLineNumbers else { return }
            gutter.isHidden = !showsLineNumbers
            updateInsets()
        }
    }

    var highlightsCurrentLine = true {
        didSet { updateCurrentLine() }
    }

    var wrapsLines = true {
        didSet {
            guard oldValue != wrapsLines else { return }
            applyWrap()
        }
    }

    /// A character-wide translucent block over the character under the caret
    /// (Vim Normal mode). The owner hides the system caret meanwhile, since
    /// iOS draws its own caret without asking `caretRect(for:)` for the width.
    var usesBlockCaret = false {
        didSet {
            guard oldValue != usesBlockCaret else { return }
            updateCurrentLine()
        }
    }

    /// The keyboard's space-bar trackpad began (true) or ended (false). The
    /// system draws its own floating caret meanwhile, so the owner shows it.
    var onFloatingCursorChange: (Bool) -> Void = { _ in }
    private(set) var isFloatingCursorActive = false

    private let gutter = CodeEditorGutterView()
    private let currentLineBand = UIView()
    private let blockCursor = UIView()
    private var cachedLineIndex: CodeLineIndex?
    private var gutterWidth: CGFloat = 0

    init() {
        // A nil container on iOS 16+ means TextKit 2.
        super.init(frame: .zero, textContainer: nil)
        gutter.textView = self
        gutter.isUserInteractionEnabled = false
        gutter.isAccessibilityElement = false
        currentLineBand.isUserInteractionEnabled = false
        currentLineBand.isHidden = true
        blockCursor.isUserInteractionEnabled = false
        blockCursor.isHidden = true
        blockCursor.layer.cornerRadius = 2
        blockCursor.accessibilityIdentifier = "workspace-file-editor.block-cursor"
        addSubview(currentLineBand)
        addSubview(blockCursor)
        addSubview(gutter)
        textContainer.lineFragmentPadding = 4
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storageDidProcessEditing),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Every character change, including undo and Use Disk Version; attribute
    /// painting is ignored.
    @objc private func storageDidProcessEditing() {
        guard textStorage.editedMask.contains(.editedCharacters) else { return }
        textDidChangeCharacters(editedRange: textStorage.editedRange, changeInLength: textStorage.changeInLength)
    }

    override var font: UIFont? {
        didSet {
            gutter.codeFont = font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
            updateInsets()
        }
    }

    /// Logical line starts for the current text, kept current edit by edit.
    var lineIndex: CodeLineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = CodeLineIndex(textStorage.mutableString)
        cachedLineIndex = index
        return index
    }

    /// Zero-based line and UTF-16 column of the caret.
    var caretLineAndColumn: (line: Int, column: Int) {
        lineAndColumn(at: selectedRange.location)
    }

    func lineAndColumn(at offset: Int) -> (line: Int, column: Int) {
        let caret = min(offset, textStorage.length)
        let index = lineIndex
        let line = index.line(containing: caret)
        return (line, caret - index.starts[line])
    }

    private func textDidChangeCharacters(editedRange: NSRange, changeInLength: Int) {
        let previousDigits = digits(for: cachedLineIndex?.lineCount ?? 1)
        if editedRange.location == NSNotFound {
            cachedLineIndex = nil
        } else {
            cachedLineIndex?.apply(editedRange: editedRange, changeInLength: changeInLength, in: textStorage.mutableString)
        }
        if digits(for: lineIndex.lineCount) != previousDigits { updateInsets() }
        gutter.setNeedsDisplay()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only the unobscured viewport: rows under the bars stay behind their blur.
        let insets = adjustedContentInset
        gutter.frame = CGRect(
            x: contentOffset.x,
            y: contentOffset.y + insets.top,
            width: gutterWidth,
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
        updateCurrentLine()
    }

    /// Selection moved: repaint the current line and its number.
    func selectionDidMove() {
        updateCurrentLine()
        gutter.setNeedsDisplay()
    }

    private func digits(for lineCount: Int) -> Int {
        max(2, String(lineCount).count)
    }

    private func updateInsets() {
        let font = self.font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        let numberFont = CodeEditorGutterView.numberFont(for: font)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        gutterWidth = showsLineNumbers ? ceil(CGFloat(digits(for: lineIndex.lineCount)) * digitWidth + 22) : 0
        let leading: CGFloat = showsLineNumbers ? gutterWidth + 6 : 12
        let insets = UIEdgeInsets(top: 12, left: leading, bottom: 24, right: 12)
        if textContainerInset != insets { textContainerInset = insets }
        setNeedsLayout()
    }

    private func applyWrap() {
        textContainer.widthTracksTextView = wrapsLines
        if !wrapsLines {
            textContainer.size = CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        }
        alwaysBounceHorizontal = !wrapsLines
        showsHorizontalScrollIndicator = !wrapsLines
        setNeedsLayout()
    }

    /// The band covers the caret's whole logical line, wrapped rows included.
    private func updateCurrentLine() {
        updateBlockCursor()
        guard highlightsCurrentLine, selectedRange.length == 0, isFirstResponder || usesBlockCaret,
              let frame = fragmentFrame(containing: selectedRange.location) else {
            currentLineBand.isHidden = true
            return
        }
        currentLineBand.isHidden = false
        currentLineBand.frame = CGRect(
            x: contentOffset.x,
            y: frame.minY + textContainerInset.top,
            width: bounds.width,
            height: max(frame.height, font?.lineHeight ?? 18)
        )
        sendSubviewToBack(currentLineBand)
    }

    /// Container-space frame of the paragraph that holds `offset`.
    func fragmentFrame(containing offset: Int) -> CGRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let documentStart = content.documentRange.location
        guard let location = content.location(documentStart, offsetBy: min(offset, textStorage.length)) else { return nil }
        if let fragment = layout.textLayoutFragment(for: location) {
            return fragment.layoutFragmentFrame
        }
        // The empty line after a trailing break has no fragment; use the caret.
        guard let position = self.position(from: beginningOfDocument, offset: offset) else { return nil }
        let caret = super.caretRect(for: position)
        return CGRect(x: 0, y: caret.minY - textContainerInset.top, width: bounds.width, height: caret.height)
    }

    // MARK: - Block cursor

    // The space-bar trackpad is UIKit's own floating cursor, the precise
    // caret movement a real text view gets for free (the SSH terminal, which
    // has no text view, emulates it with arrow keys).
    override func beginFloatingCursor(at point: CGPoint) {
        super.beginFloatingCursor(at: point)
        isFloatingCursorActive = true
        updateBlockCursor()
        onFloatingCursorChange(true)
    }

    override func endFloatingCursor() {
        super.endFloatingCursor()
        isFloatingCursorActive = false
        onFloatingCursorChange(false)
        updateBlockCursor()
    }

    private func updateBlockCursor() {
        guard usesBlockCaret, !isFloatingCursorActive, selectedRange.length == 0,
              let position = position(from: beginningOfDocument, offset: selectedRange.location) else {
            blockCursor.isHidden = true
            return
        }
        let caret = caretRect(for: position)
        guard !caret.isNull, !caret.isInfinite else {
            blockCursor.isHidden = true
            return
        }
        let font = self.font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        let width = max(2, ("M" as NSString).size(withAttributes: [.font: font]).width)
        blockCursor.isHidden = false
        blockCursor.frame = CGRect(x: caret.minX, y: caret.minY, width: width, height: caret.height)
        bringSubviewToFront(blockCursor)
        bringSubviewToFront(gutter)
    }

    // MARK: - Input

    override func insertText(_ text: String) {
        if markedTextRange == nil, inputHandler?.codeEditor(self, handleInsert: text) == true { return }
        super.insertText(text)
    }

    override func deleteBackward() {
        if markedTextRange == nil, inputHandler?.codeEditorHandleDeleteBackward(self) == true { return }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (inputHandler?.codeEditorKeyCommands(self) ?? [])
    }

    @objc func performEditorKeyCommand(_ sender: UIKeyCommand) {
        guard let command = sender.propertyList as? String else { return }
        inputHandler?.codeEditor(self, perform: command)
    }
}

/// Line numbers for the rows on screen, drawn each time the view scrolls or
/// the text changes. The view is pinned to the viewport by its text view.
final class CodeEditorGutterView: UIView {
    weak var textView: CodeEditorTextView?
    var codeFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular) {
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
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        let chrome = textView.chrome
        chrome.gutterBackground.setFill()
        UIRectFill(bounds)
        chrome.divider.setFill()
        UIRectFill(CGRect(x: bounds.width - 1 / max(1, traitCollection.displayScale), y: 0, width: 1 / max(1, traitCollection.displayScale), height: bounds.height))

        let numberFont = Self.numberFont(for: codeFont)
        let index = textView.lineIndex
        let currentLine = textView.selectedRange.length == 0 ? textView.caretLineAndColumn.line : -1
        // Container-space y at the gutter's top edge.
        let top = textView.contentOffset.y + textView.adjustedContentInset.top - textView.textContainerInset.top
        let bottom = top + bounds.height
        let documentStart = content.documentRange.location
        let right = bounds.width - 10

        func drawNumber(_ line: Int, lineTop: CGFloat, baseline: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: line == currentLine ? chrome.currentNumber : chrome.number,
            ]
            let text = String(line + 1) as NSString
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: right - width, y: lineTop + baseline - numberFont.ascender - top), withAttributes: attributes)
        }

        guard textView.textStorage.length > 0 else {
            drawNumber(0, lineTop: 0, baseline: codeFont.ascender)
            return
        }

        let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top)))?.rangeInElement.location ?? documentStart
        var lastLine = 0
        var lastBottom: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > bottom { return false }
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = index.line(containing: offset)
            let first = fragment.textLineFragments.first
            let baseline = (first?.typographicBounds.minY ?? 0) + (first?.glyphOrigin.y ?? codeFont.ascender)
            drawNumber(line, lineTop: frame.minY, baseline: baseline)
            lastLine = line
            lastBottom = frame.maxY
            return true
        }
        // The empty line after a trailing break has no layout fragment.
        if lastLine + 1 < index.lineCount, index.starts[index.lineCount - 1] == textView.textStorage.length,
           lastLine + 1 == index.lineCount - 1, lastBottom <= bottom {
            drawNumber(lastLine + 1, lineTop: lastBottom, baseline: codeFont.ascender)
        }
    }
}
