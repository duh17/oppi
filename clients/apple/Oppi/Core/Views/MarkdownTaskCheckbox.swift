import UIKit

/// The checkbox that leads a task-list item (`- [ ]`, `- [x]`, Org `[ ]`/`[X]`).
///
/// Each item is laid out so its checkbox can own a 44 × 44 pt hit area
/// without the text moving: the checkbox fills a leading column at least
/// 44 pt wide, wrapped lines hang at that column, and items are spaced so the
/// band centred on each first line is at least 44 pt tall and never overlaps
/// the next item's.
enum MarkdownTaskCheckbox {
    /// The smallest touch target, in points.
    static let hitSize: CGFloat = 44

    /// The checkbox run and the paragraph styles for an item set in `font`.
    struct Item {
        let checkbox: AttributedString
        /// The item's first paragraph: the checkbox, then text hanging at the column.
        let firstParagraph: NSParagraphStyle
        /// Any later paragraph of the same item, indented to the column.
        let laterParagraph: NSParagraphStyle
    }

    /// `line` is the source line of the item's box, when the reader knows it.
    /// `isPartial` is Org's `[-]`: some but not all of the item's own
    /// sub-items are done, drawn as a dash in the box rather than empty or
    /// checked.
    static func item(
        checked: Bool,
        palette: ThemePalette,
        font: UIFont = AppFont.messageBody,
        line: Int? = nil,
        isPartial: Bool = false
    ) -> Item {
        let column = max(hitSize, ceil(font.lineHeight * 1.6))
        let attachment = TaskCheckboxAttachment(
            isChecked: checked,
            isPartial: isPartial,
            tint: (checked || isPartial) ? palette.ui.green : palette.ui.fgDim,
            column: column,
            fallbackFont: font,
            control: line.map { ReaderTaskControl(kind: .checkbox, line: $0) }
        )
        var checkbox = AttributedString(NSAttributedString(attachment: attachment))
        // The font travels with the run, so reader text scaling reaches the glyph.
        checkbox.uiKit.font = font

        // Half the shortfall above and half below the first line keeps each
        // item's 44 pt band to itself.
        let spacing = max(0, hitSize - font.lineHeight) / 2
        let first = NSMutableParagraphStyle()
        first.headIndent = column
        first.paragraphSpacingBefore = spacing
        first.paragraphSpacing = spacing
        let later = NSMutableParagraphStyle()
        later.firstLineHeadIndent = column
        later.headIndent = column
        later.paragraphSpacing = spacing
        return Item(checkbox: checkbox, firstParagraph: first, laterParagraph: later)
    }
}

/// Draws a square checkbox SF Symbol centred in the item's leading column,
/// sized from the font of the line it sits in.
final class TaskCheckboxAttachment: NSTextAttachment, ReaderTaskControlAttachment {
    let isChecked: Bool
    /// Org's `[-]`: some but not all of the item's own sub-items are done.
    let isPartial: Bool
    let control: ReaderTaskControl?
    private let tint: UIColor
    /// Width of the leading column the glyph is centred in.
    private let column: CGFloat
    private let fallbackFont: UIFont

    override class var supportsSecureCoding: Bool { true }

    init(
        isChecked: Bool,
        isPartial: Bool = false,
        tint: UIColor,
        column: CGFloat,
        fallbackFont: UIFont,
        control: ReaderTaskControl? = nil
    ) {
        self.control = control
        self.isChecked = isChecked
        self.isPartial = isPartial
        self.tint = tint
        self.column = column
        self.fallbackFont = fallbackFont
        super.init(data: nil, ofType: nil)
        // Drawing goes through the overrides below. UIKit only speaks an
        // attachment's label in a text element when the attachment has an image.
        image = Self.placeholderImage
    }

    private static let placeholderImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    private enum Key {
        static let checked = "oppi.taskCheckbox.checked"
        static let partial = "oppi.taskCheckbox.partial"
        static let tint = "oppi.taskCheckbox.tint"
        static let column = "oppi.taskCheckbox.column"
        static let fontSize = "oppi.taskCheckbox.fontSize"
        static let line = "oppi.taskCheckbox.line"
    }

    required init?(coder: NSCoder) {
        let line = coder.decodeInteger(forKey: Key.line)
        control = line > 0 ? ReaderTaskControl(kind: .checkbox, line: line) : nil
        isChecked = coder.decodeBool(forKey: Key.checked)
        isPartial = coder.decodeBool(forKey: Key.partial)
        tint = coder.decodeObject(of: UIColor.self, forKey: Key.tint) ?? .secondaryLabel
        let column = coder.decodeDouble(forKey: Key.column)
        self.column = column > 0 ? column : MarkdownTaskCheckbox.hitSize
        let size = coder.decodeDouble(forKey: Key.fontSize)
        fallbackFont = .systemFont(ofSize: size > 0 ? size : UIFont.labelFontSize)
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(isChecked, forKey: Key.checked)
        coder.encode(isPartial, forKey: Key.partial)
        coder.encode(tint, forKey: Key.tint)
        coder.encode(Double(column), forKey: Key.column)
        coder.encode(Double(fallbackFont.pointSize), forKey: Key.fontSize)
        coder.encode(control?.line ?? 0, forKey: Key.line)
    }

    // Segments build off the main actor; UIKit reads the label on the main
    // actor through this override.
    override var accessibilityLabel: String? {
        get {
            if isPartial { return "checkbox, partially checked" }
            return isChecked ? "checkbox, checked" : "checkbox, not checked"
        }
        set {}
    }

    // MARK: - Layout and drawing

    private func symbol(font: UIFont?) -> UIImage? {
        // Small scale lands the square a little above the line's cap height.
        let configuration = UIImage.SymbolConfiguration(font: font ?? fallbackFont, scale: .small)
        let name = isPartial ? "minus.square.fill" : (isChecked ? "checkmark.square.fill" : "square")
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// The column wide, the glyph tall, centred on the line's capitals.
    private func bounds(font: UIFont?) -> CGRect {
        let lineFont = font ?? fallbackFont
        let height = ceil(symbol(font: lineFont)?.size.height ?? lineFont.capHeight)
        return CGRect(x: 0, y: ((lineFont.capHeight - height) / 2).rounded(), width: column, height: height)
    }

    private func render(font: UIFont?, size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0, let glyph = symbol(font: font) else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in
            glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2))
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        bounds(font: attributes[.font] as? UIFont)
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> UIImage? {
        render(font: attributes[.font] as? UIFont, size: bounds.size)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        bounds(font: font(in: textContainer, at: charIndex))
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        render(font: font(in: textContainer, at: charIndex), size: imageBounds.size)
    }

    private func font(in textContainer: NSTextContainer?, at index: Int) -> UIFont? {
        guard let storage = textContainer?.layoutManager?.textStorage, index < storage.length else { return nil }
        return storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont
    }
}
