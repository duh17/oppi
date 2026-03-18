import UIKit

/// Code block container with language badge, copy button, and syntax highlighting.
///
/// Renders a code block with language badge, copy button, and
/// optional syntax highlighting. Supports in-place content updates
/// for streaming.
final class NativeCodeBlockView: UIView {
    private var selectedTextPiRouter: SelectedTextPiActionRouter?
    private var selectedTextSourceContext: SelectedTextSourceContext?

    private let headerStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .center
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let languageLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let copyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let codeScrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let codeLabel: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    private let headerBackground = UIView()
    private var currentCode: String = ""
    private var highlightedText: NSAttributedString?

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var codeLabelWidthConstraint: NSLayoutConstraint?

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true

        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBackground)
        addSubview(headerStack)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(languageLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(copyButton)

        addSubview(codeScrollView)
        codeScrollView.addSubview(codeLabel)

        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        codeLabel.delegate = self
        codeScrollView.addGestureRecognizer(longPressCopyGesture)

        let widthConstraint = codeLabel.widthAnchor.constraint(equalToConstant: 0)
        codeLabelWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            headerBackground.topAnchor.constraint(equalTo: topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: headerStack.bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            codeScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            codeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor, constant: 12),
            codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            codeLabel.heightAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.heightAnchor, constant: -24),
            widthConstraint,
        ])
    }

    func configureSelectedTextPi(
        router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?
    ) {
        selectedTextPiRouter = router
        selectedTextSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        codeLabel.isSelectable = selectionEnabled
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    // periphery:ignore:parameters isOpen
    func apply(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        backgroundColor = UIColor(palette.bgDark)
        headerBackground.backgroundColor = UIColor(palette.bgHighlight)
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor

        languageLabel.text = language ?? "code"
        languageLabel.textColor = UIColor(palette.comment)
        copyButton.tintColor = UIColor(palette.fgDim)

        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        if code == currentCode, let highlighted = highlightedText {
            codeLabel.attributedText = highlighted
            return
        }

        currentCode = code
        highlightedText = nil

        codeLabel.font = font
        codeLabel.textColor = UIColor(palette.fg)
        codeLabel.attributedText = nil
        codeLabel.text = code

        let attrText = NSAttributedString(string: code, attributes: [.font: font])
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attrText.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        codeLabelWidthConstraint?.constant = ceil(boundingRect.width)
    }

    func applyHighlightedCode(_ highlighted: NSAttributedString) {
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        codeLabel.attributedText = mutable
        highlightedText = mutable

        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = mutable.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        codeLabelWidthConstraint?.constant = ceil(boundingRect.width)
    }

    @objc private func copyTapped() {
        copyCodeAndShowFeedback()
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        copyCodeAndShowFeedback()
        showCopiedFlash()
    }

    private func copyCodeAndShowFeedback() {
        UIPasteboard.general.string = currentCode
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.7)

        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: self)
    }
}

extension NativeCodeBlockView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        )
    }
}

/// UIKit table rendered as a single attributed string in a horizontal scroll view.
///
/// Uses monospaced column alignment (like the diff view) for pixel-perfect
/// columns. Much tighter and better-looking than a stack-of-stacks approach.
final class NativeTableBlockView: UIView {
    private var selectedTextPiRouter: SelectedTextPiActionRouter?
    private var selectedTextSourceContext: SelectedTextSourceContext?

    /// Inner card that wraps the scroll view. Carries the background, border,
    /// and corner radius so it shrink-wraps to content width while the outer
    /// view (sized by SwiftUI) can be full-width and transparent.
    private let cardView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 8
        v.layer.borderWidth = 1
        v.clipsToBounds = true
        return v
    }()

    private let scrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let tableLabel: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var tableLabelWidthConstraint: NSLayoutConstraint?

    /// Card width constraint — shrinks to content or expands to parent width,
    /// whichever is smaller.
    private var cardWidthConstraint: NSLayoutConstraint?

    /// Stored for long-press copy — rebuilt as markdown table text.
    private var currentHeaders: [[MarkdownInline]] = []
    private var currentRows: [[[MarkdownInline]]] = []
    /// Whether any cell contains a link (enables text view selectability for taps).
    private var hasLinks = false

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        backgroundColor = .clear

        addSubview(cardView)
        cardView.addSubview(scrollView)
        scrollView.addSubview(tableLabel)

        tableLabel.delegate = self
        scrollView.addGestureRecognizer(longPressCopyGesture)

        let labelWidthConstraint = tableLabel.widthAnchor.constraint(equalToConstant: 0)
        tableLabelWidthConstraint = labelWidthConstraint

        let cardWidth = cardView.widthAnchor.constraint(equalTo: widthAnchor)
        cardWidthConstraint = cardWidth

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidth,

            scrollView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            tableLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            tableLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            tableLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tableLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            tableLabel.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            labelWidthConstraint,
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCardWidth()
    }

    /// Update card width to min(contentWidth, boundsWidth).
    private func updateCardWidth() {
        guard let constraint = cardWidthConstraint else { return }
        let contentWidth = tableLabelWidthConstraint?.constant ?? 0
        let parentWidth = bounds.width

        if contentWidth > 0, contentWidth < parentWidth {
            if constraint.firstAnchor === cardView.widthAnchor,
               constraint.secondAnchor === widthAnchor {
                constraint.isActive = false
                let absolute = cardView.widthAnchor.constraint(equalToConstant: contentWidth)
                cardWidthConstraint = absolute
                absolute.isActive = true
            } else {
                constraint.constant = contentWidth
            }
        } else {
            if constraint.firstAnchor === cardView.widthAnchor,
               constraint.secondAnchor === widthAnchor {
                // Already relative.
            } else {
                constraint.isActive = false
                let relative = cardView.widthAnchor.constraint(equalTo: widthAnchor)
                cardWidthConstraint = relative
                relative.isActive = true
            }
        }
    }

    func configureSelectedTextPi(
        router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?
    ) {
        selectedTextPiRouter = router
        selectedTextSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        tableLabel.isSelectable = selectionEnabled
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    func apply(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], palette: ThemePalette) {
        currentHeaders = headers
        currentRows = rows

        // Detect links in any cell for selectability.
        hasLinks = Self.containsLink(headers) || rows.contains { Self.containsLink($0) }
        // Enable selectability when links are present so UITextView handles taps.
        if hasLinks {
            tableLabel.isSelectable = true
        }

        cardView.backgroundColor = UIColor(palette.bgDark)
        cardView.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor
        let attrText = Self.makeTableAttributedText(headers: headers, rows: rows, palette: palette)
        tableLabel.attributedText = attrText
        tableLabel.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attrText.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        tableLabelWidthConstraint?.constant = ceil(boundingRect.width)
        setNeedsLayout()
    }

    private static func containsLink(_ cells: [[MarkdownInline]]) -> Bool {
        cells.contains { cell in
            cell.contains { inline in
                if case .link = inline { return true }
                return false
            }
        }
    }

    /// Monospaced column width of a string — counts emoji/CJK as 2 columns.
    private static func monoColumnWidth(_ string: String) -> Int {
        var width = 0
        for scalar in string.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x20...0x7E:
                width += 1
            case 0x1100...0x115F,
                 0x2E80...0x303E,
                 0x3041...0x33BF,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xA000...0xA4CF,
                 0xAC00...0xD7AF,
                 0xF900...0xFAFF,
                 0xFE30...0xFE6F,
                 0xFF01...0xFF60,
                 0xFFE0...0xFFE6,
                 0x20000...0x2FFFF,
                 0x30000...0x3FFFF:
                width += 2
            case 0x2600...0x27BF,
                 0x1F300...0x1F9FF,
                 0x1FA00...0x1FA6F,
                 0x1FA70...0x1FAFF:
                width += 2
            case 0xFE00...0xFE0F, 0x200D, 0x20E3:
                break
            default:
                width += 1
            }
        }
        return width
    }

    private static func monoPad(_ string: String, toColumnWidth target: Int) -> String {
        let currentWidth = monoColumnWidth(string)
        let padding = max(0, target - currentWidth)
        return string + String(repeating: " ", count: padding)
    }

    private static func makeTableAttributedText(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        palette: ThemePalette
    ) -> NSAttributedString {
        let colCount = max(headers.count, rows.first?.count ?? 0)
        guard colCount > 0 else { return NSAttributedString() }

        // Compute column widths from plain text content.
        var colWidths = [Int](repeating: 0, count: colCount)
        for (index, header) in headers.enumerated() where index < colCount {
            colWidths[index] = max(colWidths[index], monoColumnWidth(plainText(from: header)))
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < colCount {
                colWidths[index] = max(colWidths[index], monoColumnWidth(plainText(from: cell)))
            }
        }

        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 3

        let headerFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let cellFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let headerColor = UIColor(palette.cyan)
        let cellColor = UIColor(palette.fg)
        let linkColor = UIColor(palette.blue)
        let dimColor = UIColor(palette.comment).withAlphaComponent(0.4)
        let headerBgColor = UIColor(palette.bgHighlight)
        let altRowBgColor = UIColor(palette.bgHighlight).withAlphaComponent(0.45)

        let headerStart = result.length
        for (index, header) in headers.enumerated() {
            let text = plainText(from: header)
            let padded = monoPad(text, toColumnWidth: colWidths[index])
            let prefix = index == 0 ? " " : " │ "
            result.append(NSAttributedString(string: prefix, attributes: [
                .font: cellFont,
                .foregroundColor: dimColor,
                .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: padded, attributes: [
                .font: headerFont,
                .foregroundColor: headerColor,
                .paragraphStyle: paragraph,
            ]))
        }
        result.append(NSAttributedString(string: " ", attributes: [
            .font: cellFont,
            .paragraphStyle: paragraph,
        ]))
        let headerEnd = result.length
        result.addAttribute(
            .backgroundColor,
            value: headerBgColor,
            range: NSRange(location: headerStart, length: headerEnd - headerStart)
        )

        for (rowIndex, row) in rows.enumerated() {
            result.append(NSAttributedString(string: "\n"))
            let rowStart = result.length

            for index in 0..<colCount {
                let inlines: [MarkdownInline] = index < row.count ? row[index] : [.text("")]
                let prefix = index == 0 ? " " : " │ "
                result.append(NSAttributedString(string: prefix, attributes: [
                    .font: cellFont,
                    .foregroundColor: dimColor,
                    .paragraphStyle: paragraph,
                ]))
                let cellText = plainText(from: inlines)
                appendTableCellInlines(
                    inlines,
                    to: result,
                    font: cellFont,
                    defaultColor: cellColor,
                    linkColor: linkColor,
                    paragraph: paragraph
                )
                // Pad remaining width with spaces.
                let padding = max(0, colWidths[index] - monoColumnWidth(cellText))
                if padding > 0 {
                    result.append(NSAttributedString(
                        string: String(repeating: " ", count: padding),
                        attributes: [.font: cellFont, .paragraphStyle: paragraph]
                    ))
                }
            }
            result.append(NSAttributedString(string: " ", attributes: [
                .font: cellFont,
                .paragraphStyle: paragraph,
            ]))

            if rowIndex % 2 == 1 {
                let rowEnd = result.length
                result.addAttribute(
                    .backgroundColor,
                    value: altRowBgColor,
                    range: NSRange(location: rowStart, length: rowEnd - rowStart)
                )
            }
        }

        return result
    }

    /// Append inline content to the result, rendering links with `.link` attribute.
    private static func appendTableCellInlines(
        _ inlines: [MarkdownInline],
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        paragraph: NSParagraphStyle
    ) {
        // Fast path: single plain text (most common table cell).
        if inlines.count == 1, case .text(let s) = inlines[0] {
            result.append(NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: defaultColor,
                .paragraphStyle: paragraph,
            ]))
            return
        }
        for inline in inlines {
            appendTableInline(
                inline, to: result, font: font,
                defaultColor: defaultColor, linkColor: linkColor,
                paragraph: paragraph
            )
        }
    }

    private static func appendTableInline(
        _ inline: MarkdownInline,
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        paragraph: NSParagraphStyle
    ) {
        switch inline {
        case .text(let s):
            result.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .link(let children, let destination):
            let text = plainText(from: children)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: paragraph,
            ]
            if let dest = destination, let url = URL(string: dest), url.scheme != nil {
                attrs[.link] = url
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        case .code(let s):
            result.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .emphasis(let children), .strong(let children), .strikethrough(let children):
            for child in children {
                appendTableInline(
                    child, to: result, font: font,
                    defaultColor: defaultColor, linkColor: linkColor,
                    paragraph: paragraph
                )
            }
        case .softBreak, .hardBreak:
            result.append(NSAttributedString(string: " ", attributes: [
                .font: font, .paragraphStyle: paragraph,
            ]))
        case .html(let raw):
            result.append(NSAttributedString(string: raw, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .image(let alt, _):
            if !alt.isEmpty {
                result.append(NSAttributedString(string: "[\(alt)]", attributes: [
                    .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
                ]))
            }
        }
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        UIPasteboard.general.string = markdownTableText()

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.7)

        showCopiedFlash()
    }

    private func markdownTableText() -> String {
        var lines: [String] = []

        let headerLine = "| " + currentHeaders.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
        lines.append(headerLine)

        let separatorLine = "| " + currentHeaders.map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(separatorLine)

        for row in currentRows {
            let rowLine = "| " + row.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
            lines.append(rowLine)
        }

        return lines.joined(separator: "\n")
    }

    /// Reconstruct markdown source text from inlines (preserves link syntax).
    private func markdownText(from inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s): return s
            case .link(let children, let dest):
                let text = plainText(from: children)
                if let dest { return "[\(text)](\(dest))" }
                return text
            case .emphasis(let children): return "*\(markdownText(from: children))*"
            case .strong(let children): return "**\(markdownText(from: children))**"
            case .code(let s): return "`\(s)`"
            case .strikethrough(let children): return "~~\(markdownText(from: children))~~"
            case .softBreak: return " "
            case .hardBreak: return "\n"
            case .html(let s): return s
            case .image(let alt, let src):
                if let src { return "![\(alt)](\(src))" }
                return alt
            }
        }.joined()
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: cardView)
    }
}

extension NativeTableBlockView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let menu = SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        ) {
            return menu
        }

        guard let router = selectedTextPiRouter,
              let sourceContext = selectedTextSourceContext,
              let fallbackText = fallbackSelectedText(in: textView, range: range) else {
            return nil
        }

        return SelectedTextPiMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
            selectedText: fallbackText,
            sourceContext: sourceContext,
            router: router
        )
    }

    private func fallbackSelectedText(in textView: UITextView, range: NSRange) -> String? {
        guard range.location != NSNotFound else { return nil }

        let fullText = textView.attributedText?.string ?? textView.text ?? ""
        let nsText = fullText as NSString
        guard range.location < nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsText.substring(with: lineRange)
        let normalized = SelectedTextPiPromptFormatter.normalizedSelectedText(lineText)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Show a flash overlay + floating "Copied" pill centered on the given view.
@MainActor
private func showCopiedOverlay(on view: UIView) {
    let palette = ThemeRuntimeState.currentPalette()
    let overlay = UIView()
    overlay.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.08)
    overlay.frame = view.bounds
    overlay.layer.cornerRadius = view.layer.cornerRadius
    overlay.isUserInteractionEnabled = false
    view.addSubview(overlay)

    let pill = CopiedPillView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
        pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        pill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    pill.alpha = 0
    pill.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    UIView.animate(withDuration: 0.15) {
        pill.alpha = 1
        pill.transform = .identity
    }

    UIView.animate(withDuration: 0.3, delay: 0.8, options: .curveEaseOut) {
        pill.alpha = 0
        pill.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        overlay.alpha = 0
    } completion: { _ in
        pill.removeFromSuperview()
        overlay.removeFromSuperview()
    }
}

private final class CopiedPillView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let palette = ThemeRuntimeState.currentPalette()

        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = UIColor(palette.fg)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

        let label = UILabel()
        label.text = "Copied"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = UIColor(palette.fg)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = UIColor(palette.bgDark).withAlphaComponent(0.85)
        layer.cornerRadius = 16
        isUserInteractionEnabled = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
