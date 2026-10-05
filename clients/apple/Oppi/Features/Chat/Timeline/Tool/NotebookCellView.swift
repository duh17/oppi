import SwiftUI
import UIKit

/// Expanded code-role tool call, painted as a notebook cell rather than a
/// markdown note with fenced blocks.
///
/// The source sits in an inset card. Nested calls and the result attach
/// underneath, on the bubble, the way a notebook attaches outputs to a cell.
/// The view does not know tool names; `NotebookCellPlan` already decided.
///
/// This view does not scroll. The timeline owns vertical pans. The reader
/// wraps the cell in its own scroll view.
@MainActor
final class NotebookCellView: UIView {
    private let contentStack = UIStackView()
    private let card = UIView()
    private let accent = UIView()
    private let cardStack = UIStackView()
    private let headerRow = UIStackView()
    private let phaseIcon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let languageLabel = UILabel()
    private let outputStack = UIStackView()
    private var sourceViews: [UITextView] = []
    private var appliedPlan: NotebookCellPlan?
    private var appliedTheme: ThemeID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "tool.notebook.cell"
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Returns whether the painted plan changed and the row should remeasure.
    @discardableResult
    func apply(_ plan: NotebookCellPlan) -> Bool {
        let theme = ThemeRuntimeState.currentThemeID()
        guard plan != appliedPlan || theme != appliedTheme else { return false }
        let sourceChanged = plan.sources != appliedPlan?.sources
            || plan.metadata != appliedPlan?.metadata
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

    private func build() {
        clipsToBounds = true
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        accent.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(accent)

        cardStack.axis = .vertical
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 6
        phaseIcon.contentMode = .scaleAspectFit
        phaseIcon.setContentHuggingPriority(.required, for: .horizontal)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.hidesWhenStopped = true
        languageLabel.font = ToolFont.small
        languageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        languageLabel.textAlignment = .right
        let spacer = UIView()
        headerRow.addArrangedSubview(phaseIcon)
        headerRow.addArrangedSubview(spinner)
        headerRow.addArrangedSubview(spacer)
        headerRow.addArrangedSubview(languageLabel)
        cardStack.addArrangedSubview(headerRow)

        outputStack.axis = .vertical
        outputStack.spacing = 6
        outputStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(outputStack)

        // Bottom stays breakable so a capped timeline row can clip the cell
        // without compressing the text. Unconstrained, including the reader,
        // the pin holds and the cell is as tall as its content.
        let bottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
            accent.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            accent.topAnchor.constraint(equalTo: card.topAnchor),
            accent.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3),
            cardStack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 10),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            phaseIcon.widthAnchor.constraint(equalToConstant: 14),
            phaseIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func paint(_ plan: NotebookCellPlan, theme: ThemeID, sourceChanged: Bool) {
        let palette = theme.palette
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.borderColor = UIColor(palette.mdCodeBlockBorder).cgColor
        let accentColor = plan.failed ? palette.red : palette.blue
        accent.backgroundColor = UIColor(accentColor)
        languageLabel.textColor = UIColor(palette.comment)
        languageLabel.text = plan.sources.compactMap(\.languageName).first
        spinner.color = UIColor(palette.blue)

        if plan.running {
            phaseIcon.isHidden = true
            spinner.startAnimating()
        } else if plan.failed {
            spinner.stopAnimating()
            phaseIcon.isHidden = false
            phaseIcon.image = UIImage(systemName: "xmark")?.applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            )
            phaseIcon.tintColor = UIColor(palette.red)
        } else {
            spinner.stopAnimating()
            phaseIcon.isHidden = true
        }
        phaseIcon.isAccessibilityElement = false
        accessibilityLabel = plan.running ? "Code cell, running" : (plan.failed ? "Code cell, failed" : "Code cell")

        if sourceChanged || sourceViews.count != plan.sources.count {
            rebuildSourceViews(plan, palette: palette)
        }
        rebuildOutput(plan, palette: palette, theme: theme)
        setNeedsLayout()
    }

    private func rebuildSourceViews(_ plan: NotebookCellPlan, palette: ThemePalette) {
        cardStack.arrangedSubviews.filter { $0 !== headerRow }.forEach {
            cardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        sourceViews = []
        for source in plan.sources {
            if let label = source.label {
                let caption = UILabel()
                caption.font = ToolFont.smallBold
                caption.textColor = UIColor(palette.comment)
                caption.text = label
                cardStack.addArrangedSubview(caption)
            }
            let view = sourceTextView()
            view.accessibilityIdentifier = "tool.notebook.code"
            applySource(source, to: view, palette: palette)
            cardStack.addArrangedSubview(view)
            sourceViews.append(view)
        }
        if !plan.metadata.isEmpty {
            let meta = UILabel()
            meta.font = ToolFont.small
            meta.textColor = UIColor(palette.fgDim)
            meta.numberOfLines = 2
            meta.text = plan.metadata.joined(separator: "\n")
            cardStack.addArrangedSubview(meta)
        }
    }

    private func applySource(_ source: NotebookCellPlan.Source, to view: UITextView, palette: ThemePalette) {
        let font = ToolFont.regular
        if shouldHighlight(source.code) {
            let highlighted = SyntaxHighlighter.highlight(source.code, language: source.syntaxLanguage, themeID: ThemeRuntimeState.currentThemeID())
            view.attributedText = highlighted
        } else {
            view.attributedText = nil
            view.font = font
            view.textColor = UIColor(palette.fg)
            view.text = source.code
        }
        view.font = font
    }

    private func shouldHighlight(_ code: String) -> Bool {
        code.utf8.count <= 4 * 1024 && code.split(separator: "\n", omittingEmptySubsequences: false).count <= 80
    }

    private func sourceTextView() -> UITextView {
        // A plain selectable text view still begins its pan when scrolling is
        // off and blocks the timeline. BaselineSafeTextView refuses that pan.
        let view = BaselineSafeTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textContainer.widthTracksTextView = true
        view.font = ToolFont.regular
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    private func rebuildOutput(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) {
        outputStack.arrangedSubviews.forEach {
            outputStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        outputStack.isHidden = !plan.hasOutputWell
        for call in plan.calls {
            outputStack.addArrangedSubview(callRow(call, palette: palette))
        }
        if plan.omittedCalls > 0 {
            outputStack.addArrangedSubview(caption("\(plan.omittedCalls) more calls", color: palette.fgDim))
        }
        if plan.callsIncomplete {
            outputStack.addArrangedSubview(caption("Some calls not recorded.", color: palette.fgDim))
        }
        switch plan.output {
        case .none:
            if plan.running && plan.calls.isEmpty {
                outputStack.addArrangedSubview(caption("Running", color: palette.fgDim))
            }
        case .stdout(let text):
            let view = sourceTextView()
            view.accessibilityIdentifier = "tool.notebook.output"
            view.font = ToolFont.regular
            view.textColor = UIColor(palette.toolOutput)
            view.text = text
            outputStack.addArrangedSubview(view)
        case .rich(let markdown):
            let markdownView = AssistantMarkdownContentView()
            markdownView.accessibilityIdentifier = "tool.notebook.output"
            markdownView.apply(configuration: .make(
                content: markdown,
                isStreaming: plan.running,
                themeID: theme,
                textSelectionEnabled: true
            ))
            outputStack.addArrangedSubview(markdownView)
        }
        if let note = plan.availabilityNote {
            outputStack.addArrangedSubview(caption(note, color: palette.comment))
        }
    }

    private func callRow(_ call: NotebookCellPlan.Call, palette: ThemePalette) -> UIView {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = 2
        let head = UIStackView()
        head.axis = .horizontal
        head.alignment = .center
        head.spacing = 6
        let pip = UIView()
        pip.layer.cornerRadius = 3
        pip.backgroundColor = UIColor(statusColor(call.status, palette: palette))
        pip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pip.widthAnchor.constraint(equalToConstant: 6),
            pip.heightAnchor.constraint(equalToConstant: 6),
        ])
        let name = UILabel()
        name.font = ToolFont.title
        name.textColor = UIColor(palette.fg)
        name.text = call.name
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        head.addArrangedSubview(pip)
        head.addArrangedSubview(name)
        if let duration = call.duration {
            let time = UILabel()
            time.font = ToolFont.small
            time.textColor = UIColor(palette.comment)
            time.text = duration
            time.setContentHuggingPriority(.required, for: .horizontal)
            head.addArrangedSubview(time)
        }
        row.addArrangedSubview(head)
        if let arguments = call.arguments {
            row.addArrangedSubview(monoLine(arguments, color: palette.fgDim))
        }
        if let error = call.error {
            row.addArrangedSubview(monoLine(error, color: palette.red))
        }
        return row
    }

    private func monoLine(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.font = ToolFont.small
        label.textColor = UIColor(color)
        label.numberOfLines = 3
        label.text = text
        return label
    }

    private func caption(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.font = ToolFont.small
        label.textColor = UIColor(color)
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func statusColor(_ status: String, palette: ThemePalette) -> Color {
        switch status {
        case "ok": return palette.green
        case "error": return palette.red
        case "running": return palette.blue
        default: return palette.fgDim
        }
    }

}
