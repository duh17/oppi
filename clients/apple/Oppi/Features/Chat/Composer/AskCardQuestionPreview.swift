import UIKit

/// The folded Ask card's question: a prominent title line over a Markdown body.
///
/// ```
/// Change Agent “QA reviewer”?          ← title, semibold, plain-text line
/// Instructions changed · Model …       ┐ body: the expanded sheet's Markdown
/// **Instructions**                     │ renderer at reader-compact size,
/// ┌ diff block ─────────────────┐      │ clipped to a height the card budgets
/// └─────────────────────────────┘      ┘ so the options stay in view, fading
///                                        out when text is cut off
/// ```
///
/// The card owns the budget: it measures the body (`naturalBodyHeight`), then
/// hands back the height to show (`bodyHeight`). Nothing here reads the request
/// beyond the text, so every ask, select, and confirm renders the same way.
@MainActor
final class AskQuestionPreviewView: UIView {
    /// Trailing room the title keeps clear for the card's expand control.
    static let controlClearance: CGFloat = 30

    private static let preferences = FullScreenReaderPreferences(
        textScale: FullScreenReaderPreferences.minimumTextScale,
        spacing: .compact
    )

    private let titleRow = UIView()
    private let titleLabel = UILabel()
    private let bodyClip = FadingClipView()
    private let markdownView = AssistantMarkdownContentView()
    private let stack = UIStackView()
    private let bodyHeightConstraint: NSLayoutConstraint
    private let bodyTrailing: NSLayoutConstraint
    private var hasTitle = false
    private var hasBody = false
    private var naturalHeight: CGFloat = 0

    override init(frame: CGRect) {
        bodyHeightConstraint = bodyClip.heightAnchor.constraint(equalToConstant: 0)
        bodyTrailing = markdownView.trailingAnchor.constraint(equalTo: bodyClip.trailingAnchor)
        super.init(frame: frame)

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(titleLabel)
        // The 32 pt row height clears the expand control's touch target, which
        // reaches 32 pt below the card's top padding.
        let minimumRowHeight = titleRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        let hugsTitle = titleRow.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor)
        hugsTitle.priority = .defaultLow
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor, constant: -Self.controlClearance),
            titleLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            titleRow.bottomAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor),
            minimumRowHeight,
            hugsTitle,
        ])

        markdownView.backgroundColor = .clear
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        bodyClip.clipsToBounds = true
        bodyClip.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: bodyClip.leadingAnchor),
            markdownView.topAnchor.constraint(equalTo: bodyClip.topAnchor),
            bodyTrailing,
            bodyHeightConstraint,
        ])

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(bodyClip)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The text of the question, split for display. `titleLineLimit` applies to
    /// the title; 0 lets it wrap fully.
    func apply(
        parts: AskCard.InlineQuestionParts,
        titleLineLimit: Int,
        colors: ComposerThemeColors
    ) {
        hasTitle = parts.title != nil
        hasBody = parts.body != nil
        titleRow.setHiddenIfChanged(!hasTitle)
        bodyClip.setHiddenIfChanged(!hasBody)

        if let title = parts.title {
            // A title over a body leads the card; a lone question keeps the
            // quieter weight it always had.
            let font = UIFont.scaled(.subheadline, hasBody ? .semibold : .medium)
            titleLabel.attributedText = Self.titleText(
                title,
                verbatim: parts.titleIsVerbatim,
                font: font,
                color: colors.fg
            )
            titleLabel.numberOfLines = titleLineLimit
            titleLabel.accessibilityLabel = "Question: \(title)"
        } else {
            titleLabel.attributedText = nil
        }

        if let body = parts.body {
            // Text selection stays off: a drag on the card scrolls it.
            markdownView.apply(configuration: .make(
                content: body,
                isStreaming: false,
                themeID: ThemeRuntimeState.currentThemeID(),
                textSelectionEnabled: false,
                readerPreferences: Self.preferences,
                renderingMode: .staticReader,
                compactCodeBlocks: true
            ))
        } else {
            markdownView.clearContent()
        }
        // Without a title, the body starts under the expand control.
        bodyTrailing.constant = hasTitle ? 0 : -Self.controlClearance
    }

    /// Height of the whole body at `width`; 0 without one.
    func naturalBodyHeight(width: CGFloat) -> CGFloat {
        guard hasBody, width > 1 else {
            naturalHeight = 0
            return 0
        }
        let bodyWidth = width - (hasTitle ? 0 : Self.controlClearance)
        markdownView.hostLayoutWidth = bodyWidth
        naturalHeight = ceil(markdownView.systemLayoutSizeFitting(
            CGSize(width: bodyWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        return naturalHeight
    }

    /// The least body the card shows before it lets the options scroll instead.
    var minimumBodyHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2)
    }

    /// Height shown for the body; text beyond it is cut off and fades out.
    var bodyHeight: CGFloat {
        get { bodyHeightConstraint.constant }
        set {
            guard abs(bodyHeightConstraint.constant - newValue) > 0.5 else { return }
            bodyHeightConstraint.constant = newValue
        }
    }

    /// Whether `bodyHeight` currently cuts off body text.
    func updateTruncation() {
        bodyClip.fadesBottom = hasBody && naturalHeight > bodyHeightConstraint.constant + 0.5
    }

    // MARK: Title text

    /// A sender-supplied title is plain text; a title split off a question may
    /// carry inline Markdown.
    static func titleText(_ text: String, verbatim: Bool, font: UIFont, color: UIColor) -> NSAttributedString {
        verbatim
            ? NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            : inlineMarkdown(text, font: font, color: color)
    }

    /// Inline Markdown (bold, italic, code) in the title's font; plain text when
    /// the string does not parse.
    static func inlineMarkdown(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                if intent.contains(.code) {
                    runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .medium)
                }
            }
            result.append(NSAttributedString(
                string: String(parsed[run.range].characters),
                attributes: [.font: runFont, .foregroundColor: color]
            ))
        }
        return result
    }
}

/// Clips its content and, when text runs past the bottom edge, fades the last
/// few points out so the cut reads as intentional.
private final class FadingClipView: UIView {
    private static let fadeHeight: CGFloat = 22
    private let fadeMask = CAGradientLayer()

    var fadesBottom = false {
        didSet {
            guard fadesBottom != oldValue else { return }
            layer.mask = fadesBottom ? fadeMask : nil
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard fadesBottom, bounds.height > 0 else { return }
        let fade = min(Self.fadeHeight, bounds.height / 2)
        let solid = (bounds.height - fade) / bounds.height
        fadeMask.frame = bounds
        fadeMask.locations = [0, NSNumber(value: solid), 1]
    }
}
