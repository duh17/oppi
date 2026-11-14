import UIKit

/// Draws one `MarkdownBadge` inline in Markdown text.
///
/// The badge sizes itself from the font of the text around it, which TextKit
/// hands over at layout, so it follows the heading or body it sits in, Dynamic
/// Type, and the reader's text scale. Separate attachments per segment let a
/// long bar wrap between segments at large sizes; a segment never clips, it
/// truncates its own text to the line.
///
/// Segments join powerline style: a segment that follows another starts with
/// the previous segment's arrow drawn on its own fill, so adjacent segments
/// meet edge to edge and a segment that wraps to a new line still shows where
/// it came from. Only the bar's last segment ends in its own arrow.
final class MarkdownBadgeAttachment: NSTextAttachment, ReaderTaskControlAttachment {
    struct Style: Equatable {
        let fill: UIColor
        let ink: UIColor
        /// Fill of the segment before this one in the same bar.
        let joinFill: UIColor?
        /// The bar's last segment points at what follows.
        let endsInArrow: Bool
        let isCapsule: Bool
    }

    private(set) var text: String
    private(set) var symbol: String?
    private(set) var style: Style
    /// The source line this badge edits, when the reader can save its file.
    let control: ReaderTaskControl?
    /// A `marker` badge: no size, nothing drawn, nothing spoken.
    let isMarker: Bool
    /// A heading's bullet, drawn alone in `style.fill` and sized to the line's text.
    let isBullet: Bool
    private var spokenLabel: String
    /// Used when TextKit does not say which font the badge sits in.
    private let fallbackFont: UIFont

    override class var supportsSecureCoding: Bool { true }

    /// One badge as an inline attachment in `palette`. A segment that follows
    /// another starts with the previous segment's arrow; the bar's last one
    /// ends in its own.
    static func attributedString(
        _ badge: MarkdownBadge,
        joiningAfter previous: MarkdownBadge?,
        endsBar: Bool,
        palette: ThemePalette
    ) -> AttributedString {
        let fill = badge.shape == .bullet
            ? outlineColor(level: badge.level ?? 1, palette: palette)
            : fill(badge.tone, palette: palette)
        let ink: UIColor = switch badge.tone {
        // A bullet is drawn in its own colour, on no fill.
        case _ where badge.shape == .bullet: fill
        case .neutral: palette.ui.fg
        case .quiet: palette.ui.fgDim
        case .accent, .warning, .success, .muted, .danger:
            ThemeColorContrast.contrastingForeground(on: fill, candidates: [palette.ui.fg, palette.ui.bg])
        }
        let attachment = MarkdownBadgeAttachment(
            badge: badge,
            style: Style(
                fill: fill,
                ink: ink,
                joinFill: previous.map { Self.fill($0.tone, palette: palette) },
                endsInArrow: endsBar,
                isCapsule: badge.shape == .capsule
            ),
            fallbackFont: AppFont.messageBody
        )
        return AttributedString(NSAttributedString(attachment: attachment))
    }

    private static func fill(_ tone: MarkdownBadge.Tone, palette: ThemePalette) -> UIColor {
        switch tone {
        case .accent: palette.ui.blue
        case .warning: palette.ui.orange
        case .success: palette.ui.green
        case .muted: palette.ui.comment
        case .danger: palette.ui.red
        case .neutral, .quiet: palette.ui.bgHighlight
        }
    }

    /// The colour of an outline heading at `level` and of its bullet, after
    /// Doom Emacs's `outline-1`…`outline-8` faces: blue, magenta, violet, then
    /// blue and magenta lightened by turns. Blue is the theme's heading colour,
    /// magenta its purple, violet the two mixed, and lightening mixes toward
    /// the text colour, which is lighter in a dark theme and darker in a light
    /// one, so every level stays readable on the page. Levels past 8 cycle.
    static func outlineColor(level: Int, palette: ThemePalette) -> UIColor {
        let blue = palette.ui.mdHeading
        let magenta = palette.ui.purple
        let text = palette.ui.fg
        return switch (max(level, 1) - 1) % 8 {
        case 0: blue
        case 1: magenta
        case 2: mix(blue, magenta, 0.5)
        case 3: mix(blue, text, 0.25)
        case 4: mix(magenta, text, 0.25)
        case 5: mix(blue, text, 0.5)
        case 6: mix(magenta, text, 0.5)
        default: mix(blue, text, 0.8)
        }
    }

    private static func mix(_ from: UIColor, _ to: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }

    init(badge: MarkdownBadge, style: Style, fallbackFont: UIFont) {
        text = badge.text
        symbol = badge.symbol
        spokenLabel = badge.label
        control = badge.control
        isMarker = badge.shape == .marker
        isBullet = badge.shape == .bullet
        self.style = style
        self.fallbackFont = fallbackFont
        super.init(data: nil, ofType: nil)
        // Drawing goes through the overrides below. UIKit only speaks an
        // attachment's label for a line that holds nothing else, such as a
        // lone planning date, when the attachment has an image.
        image = Self.placeholderImage
    }

    private static let placeholderImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    // MARK: - Coding

    private enum Key {
        static let text = "oppi.badge.text"
        static let symbol = "oppi.badge.symbol"
        static let label = "oppi.badge.label"
        static let fill = "oppi.badge.fill"
        static let ink = "oppi.badge.ink"
        static let joinFill = "oppi.badge.joinFill"
        static let endsInArrow = "oppi.badge.endsInArrow"
        static let isCapsule = "oppi.badge.isCapsule"
        static let fontSize = "oppi.badge.fontSize"
        static let control = "oppi.badge.control"
        static let line = "oppi.badge.line"
        static let isMarker = "oppi.badge.isMarker"
        static let isBullet = "oppi.badge.isBullet"
    }

    required init?(coder: NSCoder) {
        text = coder.decodeObject(of: NSString.self, forKey: Key.text) as String? ?? ""
        symbol = coder.decodeObject(of: NSString.self, forKey: Key.symbol) as String?
        spokenLabel = coder.decodeObject(of: NSString.self, forKey: Key.label) as String? ?? text
        control = (coder.decodeObject(of: NSString.self, forKey: Key.control) as String?).flatMap { name in
            ReaderTaskControl(name: name, line: String(coder.decodeInteger(forKey: Key.line)))
        }
        isMarker = coder.decodeBool(forKey: Key.isMarker)
        isBullet = coder.decodeBool(forKey: Key.isBullet)
        style = Style(
            fill: coder.decodeObject(of: UIColor.self, forKey: Key.fill) ?? .systemGray,
            ink: coder.decodeObject(of: UIColor.self, forKey: Key.ink) ?? .label,
            joinFill: coder.decodeObject(of: UIColor.self, forKey: Key.joinFill),
            endsInArrow: coder.decodeBool(forKey: Key.endsInArrow),
            isCapsule: coder.decodeBool(forKey: Key.isCapsule)
        )
        let size = coder.decodeDouble(forKey: Key.fontSize)
        fallbackFont = .systemFont(ofSize: size > 0 ? size : UIFont.labelFontSize)
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(text as NSString, forKey: Key.text)
        coder.encode(symbol as NSString?, forKey: Key.symbol)
        coder.encode(spokenLabel as NSString, forKey: Key.label)
        coder.encode(style.fill, forKey: Key.fill)
        coder.encode(style.ink, forKey: Key.ink)
        coder.encode(style.joinFill, forKey: Key.joinFill)
        coder.encode(style.endsInArrow, forKey: Key.endsInArrow)
        coder.encode(style.isCapsule, forKey: Key.isCapsule)
        coder.encode(Double(fallbackFont.pointSize), forKey: Key.fontSize)
        coder.encode(control?.kindName as NSString?, forKey: Key.control)
        coder.encode(control?.line ?? 0, forKey: Key.line)
        coder.encode(isMarker, forKey: Key.isMarker)
        coder.encode(isBullet, forKey: Key.isBullet)
    }

    // Segments build off the main actor, where `accessibilityLabel`'s setter is
    // unavailable; UIKit reads the label on the main actor through this override.
    override var accessibilityLabel: String? {
        get { spokenLabel }
        set { spokenLabel = newValue ?? "" }
    }

    // MARK: - TextKit 2

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        layout(font: attributes[.font] as? UIFont, lineWidth: proposedLineFragment.width).bounds
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> UIImage? {
        render(layout(font: attributes[.font] as? UIFont, lineWidth: bounds.width), size: bounds.size)
    }

    // MARK: - TextKit 1 (measurement)

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        layout(font: font(in: textContainer, at: charIndex), lineWidth: lineFrag.width).bounds
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        render(layout(font: font(in: textContainer, at: charIndex), lineWidth: imageBounds.width), size: imageBounds.size)
    }

    private func font(in textContainer: NSTextContainer?, at index: Int) -> UIFont? {
        guard let storage = textContainer?.layoutManager?.textStorage, index < storage.length else { return nil }
        return storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont
    }

    // MARK: - Layout

    struct Layout {
        let bounds: CGRect
        let textFont: UIFont
        let padding: CGFloat
        let arrowDepth: CGFloat
        let symbolWidth: CGFloat
        let symbolGap: CGFloat
    }

    /// Geometry for a badge in a line set in `font`, no wider than `lineWidth`.
    func layout(font: UIFont?, lineWidth: CGFloat) -> Layout {
        let lineFont = font ?? fallbackFont
        if isMarker {
            return Layout(bounds: .zero, textFont: lineFont, padding: 0, arrowDepth: 0, symbolWidth: 0, symbolGap: 0)
        }
        if isBullet {
            // A square about the height of the line's capitals, centred on
            // them, with a gap before the heading's words: the room the old
            // disclosure chevron took, so headings wrap and measure as they
            // did. Open and folded bullets share it, so a fold never moves
            // the words.
            let side = ceil(lineFont.pointSize * 0.9)
            let gap = ceil(lineFont.pointSize * 0.3)
            return Layout(
                bounds: CGRect(x: 0, y: ((lineFont.capHeight - side) / 2).rounded(), width: side + gap, height: side),
                textFont: lineFont,
                padding: 0,
                arrowDepth: 0,
                symbolWidth: side,
                symbolGap: gap
            )
        }
        // Smaller and bolder than the line, with figures that line up. Capsules
        // (tags) are quieter still.
        let scale: CGFloat = style.isCapsule ? 0.62 : 0.74
        let textFont = UIFont.monospacedDigitSystemFont(
            ofSize: lineFont.pointSize * scale,
            weight: style.isCapsule ? .medium : .semibold
        )
        let size = textFont.pointSize
        let height = ceil(textFont.lineHeight + size * 0.32)
        let padding = size * 0.5
        let arrowDepth = style.isCapsule ? 0 : height * 0.3
        let symbolImage = symbolImage(font: textFont)
        let symbolWidth = symbolImage?.size.width ?? 0
        let symbolGap = symbolImage == nil ? 0 : size * 0.3
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: textFont]).width)
        let leading = style.joinFill == nil ? 0 : arrowDepth
        let trailing = style.endsInArrow ? arrowDepth : 0
        var width = leading + padding + symbolWidth + symbolGap + textWidth + padding + trailing
        if lineWidth > 0 { width = min(width, lineWidth) }
        // Centred on the line's capitals, so it sits with the words around it.
        let y = (lineFont.capHeight - height) / 2
        return Layout(
            bounds: CGRect(x: 0, y: y.rounded(), width: ceil(width), height: height),
            textFont: textFont,
            padding: padding,
            arrowDepth: arrowDepth,
            symbolWidth: symbolWidth,
            symbolGap: symbolGap
        )
    }

    private func symbolImage(font: UIFont) -> UIImage? {
        guard let symbol else { return nil }
        let configuration = UIImage.SymbolConfiguration(font: font, scale: isBullet ? .medium : .small)
        return UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(style.ink, renderingMode: .alwaysOriginal)
    }

    // MARK: - Drawing

    private var isFolded: Bool {
        control?.kind == .fold(isExpanded: false)
    }

    private func render(_ layout: Layout, size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(layout, in: CGRect(origin: .zero, size: size))
        }
    }

    private func draw(_ layout: Layout, in rect: CGRect) {
        let height = rect.height
        if isBullet {
            // Sized from the square TextKit measured, not the font it draws
            // with, which can differ (the largest text sizes): the shape always
            // fills its own room.
            let slot = CGRect(x: 0, y: 0, width: height, height: height)
            if isFolded {
                // A folded bullet sits in a faint disc of its colour, as an
                // outliner marks a bullet with hidden children.
                style.fill.withAlphaComponent(0.2).setFill()
                UIBezierPath(ovalIn: slot).fill()
            }
            if let image = symbolImage(font: .systemFont(ofSize: height * 0.72, weight: .semibold)) {
                image.draw(at: CGPoint(x: slot.midX - image.size.width / 2, y: slot.midY - image.size.height / 2))
            }
            return
        }
        let depth = layout.arrowDepth
        let body = UIBezierPath()
        if style.isCapsule {
            body.append(UIBezierPath(roundedRect: rect, cornerRadius: height / 2))
        } else {
            let radius = style.joinFill == nil ? height * 0.22 : 0
            let tipX = style.endsInArrow ? rect.maxX - depth : rect.maxX
            body.move(to: CGPoint(x: radius, y: 0))
            body.addLine(to: CGPoint(x: tipX, y: 0))
            if style.endsInArrow { body.addLine(to: CGPoint(x: rect.maxX, y: height / 2)) }
            body.addLine(to: CGPoint(x: tipX, y: height))
            body.addLine(to: CGPoint(x: radius, y: height))
            if radius > 0 {
                body.addArc(withCenter: CGPoint(x: radius, y: height - radius), radius: radius,
                            startAngle: .pi / 2, endAngle: .pi, clockwise: true)
                body.addLine(to: CGPoint(x: 0, y: radius))
                body.addArc(withCenter: CGPoint(x: radius, y: radius), radius: radius,
                            startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
            } else {
                body.addLine(to: CGPoint(x: 0, y: 0))
            }
            body.close()
        }
        style.fill.setFill()
        body.fill()

        if let joinFill = style.joinFill {
            let arrow = UIBezierPath()
            arrow.move(to: .zero)
            arrow.addLine(to: CGPoint(x: depth, y: height / 2))
            arrow.addLine(to: CGPoint(x: 0, y: height))
            if joinFill.isEqual(style.fill) {
                // Two segments of one fill part with a thin chevron instead.
                style.ink.withAlphaComponent(0.35).setStroke()
                arrow.lineWidth = max(1, height / 24)
                arrow.stroke()
            } else {
                arrow.close()
                joinFill.setFill()
                arrow.fill()
            }
        }

        var x = (style.joinFill == nil ? 0 : depth) + layout.padding
        let contentRight = rect.maxX - layout.padding - (style.endsInArrow ? depth : 0)
        if let image = symbolImage(font: layout.textFont) {
            image.draw(at: CGPoint(x: x, y: (height - image.size.height) / 2))
            x += layout.symbolWidth + layout.symbolGap
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textHeight = layout.textFont.lineHeight
        (text as NSString).draw(
            in: CGRect(x: x, y: (height - textHeight) / 2, width: max(0, contentRight - x), height: textHeight),
            withAttributes: [.font: layout.textFont, .foregroundColor: style.ink, .paragraphStyle: paragraph]
        )
    }
}
