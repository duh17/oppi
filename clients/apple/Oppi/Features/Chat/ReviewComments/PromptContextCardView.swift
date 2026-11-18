import UIKit

/// One place a sent or queued message carried, drawn in full: where it is, the selected text
/// (code in its language, else a quote), and the person's note. The user's message and the
/// queue draw the same card, so a message shows what it sent.
///
/// The place line is a button when the place can open (`PromptContextItem.opensPlace`) and
/// the host gives `onOpen`; touch and accessibility activation both run `onOpen`. Ids, under
/// the host's `identifier`: `<id>.place`, `<id>.quote`, `<id>.note`.
final class PromptContextCardView: UIView {
    /// The host's open action: the item and the place line it opens from.
    typealias Open = (PromptContextItem, UIView) -> Void

    let item: PromptContextItem

    init(item: PromptContextItem, identifier: String?, textColor: UIColor, palette: ThemePalette, onOpen: Open?) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = textColor.withAlphaComponent(0.06)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = textColor.withAlphaComponent(0.14).cgColor
        accessibilityIdentifier = identifier

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        let opens = item.opensPlace && onOpen != nil
        let place = PlaceControl(item: item, opens: opens, textColor: textColor, palette: palette)
        place.accessibilityIdentifier = identifier.map { "\($0).place" }
        if opens, let onOpen {
            place.addAction(UIAction { [weak place] _ in
                guard let place else { return }
                onOpen(item, place)
            }, for: .touchUpInside)
        }
        stack.addArrangedSubview(place)

        if let quote = item.quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let quoteID = identifier.map { "\($0).quote" }
            stack.addArrangedSubview(item.quoteCodeLanguage.map {
                Self.codeBlock(quote, language: $0, identifier: quoteID, palette: palette)
            } ?? Self.quoteBlock(quote, identifier: quoteID, textColor: textColor, palette: palette))
        }

        if let note = item.note, !note.isEmpty {
            let label = Self.label(font: AppFont.messageBody, color: textColor)
            label.text = note
            label.accessibilityIdentifier = identifier.map { "\($0).note" }
            stack.addArrangedSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    /// The selection as code, wrapped and whole, on the code-block fill.
    private static func codeBlock(
        _ code: String,
        language: SyntaxLanguage,
        identifier: String?,
        palette: ThemePalette
    ) -> UIView {
        let label = label(font: UIFont.scaledMonospaced(.footnote), color: palette.ui.fg)
        label.lineBreakMode = .byCharWrapping
        let highlighted = NSMutableAttributedString(
            attributedString: language == .unknown
                ? NSAttributedString(string: code, attributes: [.foregroundColor: palette.ui.fg])
                : SyntaxHighlighter.highlight(code, language: language)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let whole = NSRange(location: 0, length: highlighted.length)
        highlighted.addAttribute(.font, value: label.font as Any, range: whole)
        highlighted.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        label.attributedText = highlighted
        label.accessibilityLabel = code
        label.accessibilityIdentifier = identifier

        let block = UIView()
        block.translatesAutoresizingMaskIntoConstraints = false
        block.backgroundColor = palette.ui.bgHighlight
        block.layer.cornerRadius = 6
        block.layer.cornerCurve = .continuous
        block.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: block.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -8),
        ])
        return block
    }

    /// The selection as prose, behind a quote bar.
    private static func quoteBlock(
        _ quote: String,
        identifier: String?,
        textColor: UIColor,
        palette: ThemePalette
    ) -> UIView {
        let label = label(font: UIFont.scaled(.subheadline), color: textColor.withAlphaComponent(0.82))
        label.text = quote
        label.accessibilityIdentifier = identifier
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = palette.ui.comment.withAlphaComponent(0.7)
        bar.layer.cornerRadius = 1.5
        let row = UIStackView(arrangedSubviews: [bar, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 8
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        return row
    }

    /// Where the item points: its icon and place, a button that opens it when it can.
    private final class PlaceControl: UIControl {
        init(item: PromptContextItem, opens: Bool, textColor: UIColor, palette: ThemePalette) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let tint = opens ? palette.ui.blue : textColor.withAlphaComponent(0.75)
            let icon = UIImageView(image: UIImage.scaledSymbol(item.placeSymbolName, style: .caption1, color: tint))
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UILabel()
            label.font = UIFont.scaledMonospaced(.caption1)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = tint
            label.text = item.placeTitle
            // A path keeps its file name; a message's start keeps its first words.
            label.lineBreakMode = item.path?.isEmpty == false ? .byTruncatingMiddle : .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.translatesAutoresizingMaskIntoConstraints = false
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 5
            // The control takes the touch, not the stack inside it.
            row.isUserInteractionEnabled = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
            isEnabled = opens
            isAccessibilityElement = true
            accessibilityLabel = item.placeTitle
            accessibilityTraits = opens ? .button : .staticText
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.6 : 1 }
        }

        /// VoiceOver runs the same action a tap does.
        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            sendActions(for: .touchUpInside)
            return true
        }
    }
}
