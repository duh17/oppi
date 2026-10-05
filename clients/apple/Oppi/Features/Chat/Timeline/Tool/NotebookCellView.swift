import SwiftUI
import UIKit

/// Expanded code-role tool call, painted as a notebook cell rather than a
/// markdown note with fenced blocks.
///
/// The source sits in an inset card. Nested calls and the result hang off a
/// rail underneath, the way a notebook attaches outputs to its cell. The row
/// header already shows status, glyph, duration, call count, and language, so
/// the cell repeats none of them. The view does not know tool names;
/// `NotebookCellPlan` already decided.
///
/// Inline, the cell is a preview: text is not selectable, so a double-tap
/// reaches the row and opens the reader, and long sections are trimmed so the
/// calls and output stay visible. The reader shows everything, selectable,
/// with review comments.
///
/// This view does not scroll. The timeline owns vertical pans. The reader
/// wraps the cell in its own scroll view.
@MainActor
final class NotebookCellView: UIView, UITextViewDelegate {
    enum Mode {
        case inline
        case reader(ReaderSelection)
    }

    /// Review-comment sources for the reader. Nil contexts still select and copy.
    struct ReaderSelection {
        var router: ReviewCommentSelectionRouter?
        var code: ReviewCommentSourceContext?
        var output: ReviewCommentSourceContext?
        var markdown: ReviewCommentSourceContext?
    }

    /// Inline preview budgets. The row viewport caps the cell at 620 pt;
    /// trimming keeps a long script from hiding its calls and output.
    private enum InlineLimit {
        static let codeLines = 12
        static let codeCharacters = 2_400
        static let calls = 6
        static let outputLines = 10
        static let outputCharacters = 1_600
    }

    private let mode: Mode
    private let contentStack = UIStackView()
    private let card = UIView()
    private let accent = UIView()
    private let cardStack = UIStackView()
    private let attachments = UIView()
    private let rail = UIView()
    private let attachmentStack = UIStackView()
    private let fadeMask = CAGradientLayer()
    private var appliedPlan: NotebookCellPlan?
    private var appliedTheme: ThemeID?

    init(mode: Mode = .inline) {
        self.mode = mode
        super.init(frame: .zero)
        accessibilityIdentifier = "tool.notebook.cell"
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var isReader: Bool {
        if case .reader = mode { return true }
        return false
    }

    private var readerSelection: ReaderSelection? {
        if case .reader(let selection) = mode { return selection }
        return nil
    }

    /// Returns whether the painted plan changed and the row should remeasure.
    @discardableResult
    func apply(_ plan: NotebookCellPlan) -> Bool {
        let theme = ThemeRuntimeState.currentThemeID()
        guard plan != appliedPlan || theme != appliedTheme else { return false }
        let sourceChanged = plan.sources != appliedPlan?.sources
            || plan.metadata != appliedPlan?.metadata
            || plan.failed != appliedPlan?.failed
            || theme != appliedTheme
        appliedPlan = plan
        appliedTheme = theme
        paint(plan, theme: theme, sourceChanged: sourceChanged)
        return true
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width > 1 ? targetSize.width : max(1, bounds.width)
        let fitted = contentStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(48, ceil(fitted.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFade()
    }

    // MARK: - Build

    private func build() {
        clipsToBounds = true
        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.clipsToBounds = true
        accent.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(accent)

        cardStack.axis = .vertical
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1
        attachments.addSubview(rail)
        attachmentStack.axis = .vertical
        attachmentStack.spacing = 12
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachments.addSubview(attachmentStack)

        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(attachments)

        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]

        // The content never stretches and never squeezes. Taller than its
        // content, the cell leaves space below (the equality sits under label
        // hugging). Shorter, as in a capped timeline row, the cap breaks below
        // label compression resistance (750) and the cell clips. Unconstrained,
        // including the reader, the equality holds and the cell fits its content.
        let bottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .fittingSizeLevel
        let cap = contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        cap.priority = UILayoutPriority(749)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
            cap,
            accent.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            accent.topAnchor.constraint(equalTo: card.topAnchor),
            accent.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3),
            cardStack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 10),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            // The rail continues the card's accent edge down through the outputs.
            rail.leadingAnchor.constraint(equalTo: attachments.leadingAnchor, constant: 0.5),
            rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: attachments.topAnchor),
            rail.bottomAnchor.constraint(equalTo: attachments.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 11),
            attachmentStack.trailingAnchor.constraint(equalTo: attachments.trailingAnchor, constant: -2),
            attachmentStack.topAnchor.constraint(equalTo: attachments.topAnchor, constant: 2),
            attachmentStack.bottomAnchor.constraint(equalTo: attachments.bottomAnchor, constant: -2),
        ])
    }

    // MARK: - Paint

    private func paint(_ plan: NotebookCellPlan, theme: ThemeID, sourceChanged: Bool) {
        let palette = theme.palette
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.borderColor = UIColor(palette.mdCodeBlockBorder).cgColor
        accent.backgroundColor = UIColor(plan.failed ? palette.red : palette.blue)
        rail.backgroundColor = UIColor((plan.failed ? palette.red : palette.comment).opacity(0.3))
        accessibilityLabel = plan.running ? "Code cell, running" : (plan.failed ? "Code cell, failed" : "Code cell")

        if sourceChanged || cardStack.arrangedSubviews.isEmpty {
            rebuildSource(plan, palette: palette, theme: theme)
        }
        rebuildAttachments(plan, palette: palette, theme: theme)
        setNeedsLayout()
    }

    private func rebuildSource(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) {
        cardStack.arrangedSubviews.forEach {
            cardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for source in plan.sources {
            if let label = source.label {
                cardStack.addArrangedSubview(sectionCaption(label, color: palette.comment))
            }
            // Leading lines stay so review-comment line numbers match the source.
            var code = Substring(source.code)
            while code.last?.isNewline == true { code = code.dropLast() }
            let shown = isReader
                ? Trimmed(text: String(code), hiddenLines: 0)
                : Trimmed(String(code), lines: InlineLimit.codeLines, characters: InlineLimit.codeCharacters)
            let view = textView()
            view.accessibilityIdentifier = "tool.notebook.code"
            paintCode(shown.text, language: source.syntaxLanguage, into: view, palette: palette, theme: theme)
            cardStack.addArrangedSubview(view)
            if shown.hiddenLines > 0 {
                cardStack.addArrangedSubview(moreLabel(lines: shown.hiddenLines, palette: palette))
            }
        }
        if !plan.metadata.isEmpty {
            let meta = UILabel()
            meta.font = ToolFont.small
            meta.textColor = UIColor(palette.fgDim)
            meta.numberOfLines = isReader ? 0 : 2
            meta.text = plan.metadata.joined(separator: "\n")
            cardStack.setCustomSpacing(10, after: cardStack.arrangedSubviews.last ?? meta)
            cardStack.addArrangedSubview(meta)
        }
    }

    private func paintCode(
        _ code: String,
        language: SyntaxLanguage,
        into view: UITextView,
        palette: ThemePalette,
        theme: ThemeID
    ) {
        let font = ToolFont.regular
        if shouldHighlight(code) {
            let highlighted = NSMutableAttributedString(
                attributedString: SyntaxHighlighter.highlight(code, language: language, themeID: theme)
            )
            highlighted.addAttribute(
                .font, value: font, range: NSRange(location: 0, length: highlighted.length)
            )
            view.attributedText = highlighted
        } else {
            view.attributedText = nil
            view.font = font
            view.textColor = UIColor(palette.fg)
            view.text = code
        }
    }

    private func shouldHighlight(_ code: String) -> Bool {
        code.utf8.count <= 16 * 1024 && code.split(separator: "\n", omittingEmptySubsequences: false).count <= 400
    }

    private func rebuildAttachments(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) {
        attachmentStack.arrangedSubviews.forEach {
            attachmentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        attachments.isHidden = !plan.hasOutputWell

        if !plan.calls.isEmpty || plan.omittedCalls > 0 || plan.callsIncomplete {
            attachmentStack.addArrangedSubview(callsSection(plan, palette: palette))
        }
        if let output = outputSection(plan, palette: palette, theme: theme) {
            attachmentStack.addArrangedSubview(output)
        } else if plan.running && plan.calls.isEmpty {
            attachmentStack.addArrangedSubview(caption("Running…", color: palette.fgDim))
        }
        if let note = plan.availabilityNote {
            attachmentStack.addArrangedSubview(caption(note, color: palette.comment))
        }
    }

    private func callsSection(_ plan: NotebookCellPlan, palette: ThemePalette) -> UIView {
        let section = sectionStack()
        section.addArrangedSubview(sectionCaption("CALLS", color: palette.comment))
        let shown = isReader ? plan.calls[...] : plan.calls.prefix(InlineLimit.calls)
        for call in shown {
            section.addArrangedSubview(callRow(call, palette: palette))
        }
        let hidden = plan.calls.count - shown.count + plan.omittedCalls
        if hidden > 0 {
            section.addArrangedSubview(caption("+\(hidden) more \(hidden == 1 ? "call" : "calls")", color: palette.fgDim))
        }
        if plan.callsIncomplete {
            section.addArrangedSubview(caption("Some calls not recorded.", color: palette.fgDim))
        }
        return section
    }

    private func outputSection(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) -> UIView? {
        let body: UIView
        var hiddenLines = 0
        switch plan.output {
        case .none:
            return nil
        case .stdout(let text):
            let shown = isReader
                ? Trimmed(text: text, hiddenLines: 0)
                : Trimmed(text, lines: InlineLimit.outputLines, characters: InlineLimit.outputCharacters)
            hiddenLines = shown.hiddenLines
            let view = textView()
            view.accessibilityIdentifier = "tool.notebook.output"
            view.font = ToolFont.regular
            view.textColor = UIColor(palette.toolOutput)
            view.text = shown.text
            body = view
        case .rich(let markdown):
            let view = AssistantMarkdownContentView()
            view.accessibilityIdentifier = "tool.notebook.output"
            view.apply(configuration: .make(
                content: markdown,
                isStreaming: plan.running,
                themeID: theme,
                textSelectionEnabled: isReader,
                reviewCommentSelectionRouter: readerSelection?.router,
                reviewCommentSourceContext: readerSelection?.markdown
            ))
            body = view
        }
        let section = sectionStack()
        section.addArrangedSubview(sectionCaption(
            plan.failed ? "OUTPUT · ERROR" : "OUTPUT",
            color: plan.failed ? palette.red : palette.comment
        ))
        section.addArrangedSubview(body)
        if hiddenLines > 0 {
            section.addArrangedSubview(moreLabel(lines: hiddenLines, palette: palette))
        }
        return section
    }

    private func callRow(_ call: NotebookCellPlan.Call, palette: ThemePalette) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 6
        row.accessibilityIdentifier = "tool.notebook.call"

        let lineHeight = ToolFont.regular.lineHeight
        let icon = UIImageView(image: UIImage(systemName: statusSymbol(call.status))?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        icon.tintColor = UIColor(statusColor(call.status, palette: palette))
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: lineHeight),
        ])
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false

        // Name and arguments share one label so they wrap together in the
        // reader and truncate together inline.
        let text = NSMutableAttributedString(string: call.name, attributes: [
            .font: ToolFont.title,
            .foregroundColor: UIColor(palette.fg),
        ])
        if let arguments = call.arguments {
            text.append(NSAttributedString(string: "  " + arguments, attributes: [
                .font: ToolFont.regular,
                .foregroundColor: UIColor(palette.fgDim),
            ]))
        }
        let label = UILabel()
        label.attributedText = text
        label.numberOfLines = isReader ? 0 : 1
        label.lineBreakMode = isReader ? .byWordWrapping : .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = UIStackView(arrangedSubviews: [label])
        column.axis = .vertical
        column.spacing = 2
        if let error = call.error {
            let errorLabel = UILabel()
            errorLabel.font = ToolFont.small
            errorLabel.textColor = UIColor(palette.red)
            errorLabel.numberOfLines = isReader ? 0 : 2
            errorLabel.text = error
            column.addArrangedSubview(errorLabel)
        }
        row.addArrangedSubview(icon)
        row.addArrangedSubview(column)
        if let duration = call.duration {
            let time = UILabel()
            time.font = ToolFont.small
            time.textColor = UIColor(palette.comment)
            time.text = duration
            time.setContentHuggingPriority(.required, for: .horizontal)
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(time)
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = [call.name, call.arguments, call.status, call.duration, call.error]
            .compactMap { $0 }.joined(separator: ", ")
        return row
    }

    // MARK: - Pieces

    private func textView() -> UITextView {
        // A plain selectable text view still begins its pan when scrolling is
        // off and blocks the timeline. BaselineSafeTextView refuses that pan.
        let view = BaselineSafeTextView()
        view.isEditable = false
        // Inline text must not select: a double-tap belongs to the row and
        // opens the reader. The reader selects and comments.
        view.isSelectable = isReader
        view.delegate = isReader ? self : nil
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textContainer.widthTracksTextView = true
        view.font = ToolFont.regular
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    private func sectionStack() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func sectionCaption(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: ToolFont.smallBold,
            .foregroundColor: UIColor(color),
            .kern: 1.2,
        ])
        label.accessibilityTraits = .header
        return label
    }

    private func moreLabel(lines: Int, palette: ThemePalette) -> UILabel {
        caption("+\(lines) more \(lines == 1 ? "line" : "lines")", color: palette.comment)
    }

    private func caption(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.font = ToolFont.small
        label.textColor = UIColor(color)
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "running": return "circle.dotted"
        default: return "minus.circle.fill"
        }
    }

    private func statusColor(_ status: String, palette: ThemePalette) -> Color {
        switch status {
        case "ok": return palette.green
        case "error": return palette.red
        case "running": return palette.blue
        default: return palette.fgDim
        }
    }

    /// Inline, a cell taller than the capped row fades out instead of ending
    /// on a sliced line. The mask is alpha-only, so it suits any background.
    private func updateFade() {
        let clipped = !isReader && contentStack.frame.maxY > bounds.height + 1 && bounds.height > 64
        guard clipped else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let fade: CGFloat = 36
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.locations = [0, NSNumber(value: Double((bounds.height - fade) / bounds.height)), 1]
        CATransaction.commit()
        if layer.mask !== fadeMask { layer.mask = fadeMask }
    }

    // MARK: - UITextViewDelegate

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        let action = MarkdownLinkInteractionSupport.classify(url, workspaceID: nil)
        guard case .webLink = action else { return defaultAction }
        return MarkdownLinkInteractionSupport.primaryAction(for: action, defaultAction: defaultAction)
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let selection = readerSelection else { return nil }
        let context = textView.accessibilityIdentifier == "tool.notebook.code" ? selection.code : selection.output
        return ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selection.router,
            sourceContext: context
        )
    }
}

/// Leading slice of a long text for the inline preview.
private struct Trimmed {
    var text: String
    var hiddenLines: Int

    init(text: String, hiddenLines: Int) {
        self.text = text
        self.hiddenLines = hiddenLines
    }

    /// Keeps at most `lines` lines and `characters` characters. A line cut
    /// mid-way ends in an ellipsis; whole hidden lines are counted.
    init(_ source: String, lines: Int, characters: Int) {
        let body = source.trimmingCharacters(in: .newlines)
        let all = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines || body.count > characters else {
            self.init(text: body, hiddenLines: 0)
            return
        }
        var kept = all.prefix(lines).joined(separator: "\n")
        var keptLines = min(lines, all.count)
        var cut = false
        if kept.count > characters {
            kept = String(kept.prefix(characters))
            keptLines = kept.split(separator: "\n", omittingEmptySubsequences: false).count
            cut = true
        }
        self.init(text: cut ? kept + "…" : kept, hiddenLines: all.count - keptLines)
    }
}
