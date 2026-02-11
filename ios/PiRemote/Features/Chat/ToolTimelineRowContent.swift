import SwiftUI
import UIKit

/// Native UIKit tool row used by timeline migration.
///
/// Supports both collapsed and expanded presentation for non-file tools, so
/// row expansion no longer swaps between native and SwiftUI renderers.
struct ToolTimelineRowConfiguration: UIContentConfiguration {
    let title: String
    let preview: String?
    let expandedText: String?
    let expandedCommandText: String?
    let expandedOutputText: String?
    let showSeparatedCommandAndOutput: Bool
    let copyCommandText: String?
    let copyOutputText: String?
    let trailing: String?
    let titleLineBreakMode: NSLineBreakMode
    let toolNamePrefix: String?
    let toolNameColor: UIColor
    let editAdded: Int?
    let editRemoved: Int?
    let isExpanded: Bool
    let isDone: Bool
    let isError: Bool

    func makeContentView() -> any UIView & UIContentView {
        ToolTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> ToolTimelineRowConfiguration {
        self
    }
}

final class ToolTimelineRowContentView: UIView, UIContentView {
    private static let maxValidHeight: CGFloat = 10_000
    private static let maxShellHighlightBytes = 64 * 1024
    private static let maxANSIHighlightBytes = 64 * 1024

    private let statusImageView = UIImageView()
    private let titleLabel = UILabel()
    private let trailingStack = UIStackView()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let trailingLabel = UILabel()
    private let bodyStack = UIStackView()
    private let previewLabel = UILabel()
    private let commandContainer = UIView()
    private let commandLabel = UILabel()
    private let outputContainer = UIView()
    private let outputLabel = UILabel()
    private let expandedContainer = UIView()
    private let expandedLabel = UILabel()
    private let borderView = UIView()

    private var currentConfiguration: ToolTimelineRowConfiguration
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?

    private lazy var commandDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCommandDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var outputDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleOutputDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var expandedDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleExpandedDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var commandSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: commandDoubleTapGesture)
        return recognizer
    }()

    private lazy var outputSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: outputDoubleTapGesture)
        return recognizer
    }()

    private lazy var expandedSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: expandedDoubleTapGesture)
        return recognizer
    }()

    init(configuration: ToolTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ToolTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let fitted = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
        return Self.sanitizedFittingSize(fitted, fallbackWidth: targetSize.width)
    }

    private static func sanitizedFittingSize(_ size: CGSize, fallbackWidth: CGFloat) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : max(1, fallbackWidth)

        let rawHeight: CGFloat
        if size.height.isFinite {
            rawHeight = max(1, size.height)
        } else {
            rawHeight = 44
        }

        let height = min(rawHeight, Self.maxValidHeight)
        return CGSize(width: width, height: height)
    }

    private func setupViews() {
        backgroundColor = .clear

        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.layer.cornerRadius = 10
        borderView.layer.borderWidth = 1

        addSubview(borderView)

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(Color.tokyoFg)
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.axis = .horizontal
        trailingStack.alignment = .firstBaseline
        trailingStack.spacing = 4
        trailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        addedLabel.textColor = UIColor(Color.tokyoGreen)

        removedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        removedLabel.textColor = UIColor(Color.tokyoRed)

        trailingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trailingLabel.textColor = UIColor(Color.tokyoComment)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = UIColor(Color.tokyoFgDim)
        previewLabel.numberOfLines = 3

        commandContainer.layer.cornerRadius = 6
        commandContainer.backgroundColor = UIColor(Color.tokyoBgHighlight.opacity(0.9))
        commandContainer.layer.borderWidth = 1
        commandContainer.layer.borderColor = UIColor(Color.tokyoBlue.opacity(0.35)).cgColor

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.numberOfLines = 0
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.textColor = UIColor(Color.tokyoFg)

        outputContainer.layer.cornerRadius = 6
        outputContainer.backgroundColor = UIColor(Color.tokyoBgDark)
        outputContainer.layer.borderWidth = 1
        outputContainer.layer.borderColor = UIColor(Color.tokyoComment.opacity(0.2)).cgColor

        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputLabel.numberOfLines = 0
        outputLabel.lineBreakMode = .byCharWrapping
        outputLabel.textColor = UIColor(Color.tokyoFg)

        expandedContainer.layer.cornerRadius = 6
        expandedContainer.backgroundColor = UIColor(Color.tokyoBgDark.opacity(0.9))

        expandedLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        expandedLabel.numberOfLines = 0
        expandedLabel.lineBreakMode = .byCharWrapping

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = 4
        bodyStackCollapsedHeightConstraint = bodyStack.heightAnchor.constraint(equalToConstant: 0)

        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)

        commandContainer.addSubview(commandLabel)
        outputContainer.addSubview(outputLabel)
        expandedContainer.addSubview(expandedLabel)
        bodyStack.addArrangedSubview(previewLabel)
        bodyStack.addArrangedSubview(commandContainer)
        bodyStack.addArrangedSubview(outputContainer)
        bodyStack.addArrangedSubview(expandedContainer)

        commandContainer.isUserInteractionEnabled = true
        outputContainer.isUserInteractionEnabled = true
        expandedContainer.isUserInteractionEnabled = true

        commandContainer.addGestureRecognizer(commandDoubleTapGesture)
        outputContainer.addGestureRecognizer(outputDoubleTapGesture)
        expandedContainer.addGestureRecognizer(expandedDoubleTapGesture)

        commandContainer.addGestureRecognizer(commandSingleTapBlocker)
        outputContainer.addGestureRecognizer(outputSingleTapBlocker)
        expandedContainer.addGestureRecognizer(expandedSingleTapBlocker)

        commandContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        outputContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        expandedContainer.addInteraction(UIContextMenuInteraction(delegate: self))

        borderView.addSubview(statusImageView)
        borderView.addSubview(titleLabel)
        borderView.addSubview(trailingStack)
        borderView.addSubview(bodyStack)

        NSLayoutConstraint.activate([
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.topAnchor.constraint(equalTo: topAnchor),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusImageView.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            statusImageView.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 7),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 5),
            titleLabel.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 6),

            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            trailingStack.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),

            bodyStack.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            bodyStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),
            bodyStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyStack.bottomAnchor.constraint(equalTo: borderView.bottomAnchor, constant: -6),

            commandLabel.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 6),
            commandLabel.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -6),
            commandLabel.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: 5),
            commandLabel.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -5),

            outputLabel.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor, constant: 6),
            outputLabel.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor, constant: -6),
            outputLabel.topAnchor.constraint(equalTo: outputContainer.topAnchor, constant: 5),
            outputLabel.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor, constant: -5),

            expandedLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 6),
            expandedLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -6),
            expandedLabel.topAnchor.constraint(equalTo: expandedContainer.topAnchor, constant: 5),
            expandedLabel.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -5),
        ])
    }

    private func apply(configuration: ToolTimelineRowConfiguration) {
        currentConfiguration = configuration

        titleLabel.attributedText = Self.styledTitle(
            title: configuration.title,
            toolNamePrefix: configuration.toolNamePrefix,
            toolNameColor: configuration.toolNameColor
        )
        titleLabel.lineBreakMode = configuration.titleLineBreakMode
        titleLabel.numberOfLines = configuration.titleLineBreakMode == .byTruncatingMiddle ? 1 : 3

        if let added = configuration.editAdded, let removed = configuration.editRemoved {
            addedLabel.text = added > 0 ? "+\(added)" : nil
            addedLabel.isHidden = addedLabel.text == nil

            removedLabel.text = removed > 0 ? "-\(removed)" : nil
            removedLabel.isHidden = removedLabel.text == nil

            if added == 0, removed == 0 {
                trailingLabel.text = "modified"
                trailingLabel.isHidden = false
            } else {
                trailingLabel.text = nil
                trailingLabel.isHidden = true
            }
        } else {
            addedLabel.text = nil
            addedLabel.isHidden = true
            removedLabel.text = nil
            removedLabel.isHidden = true
            trailingLabel.text = configuration.trailing
            trailingLabel.isHidden = configuration.trailing == nil
        }

        trailingStack.isHidden = addedLabel.isHidden && removedLabel.isHidden && trailingLabel.isHidden

        let preview = configuration.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showPreview = !configuration.isExpanded && !(preview?.isEmpty ?? true)
        previewLabel.text = preview
        previewLabel.isHidden = !showPreview

        let expandedText = configuration.expandedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showLegacyExpanded = configuration.isExpanded
            && !configuration.showSeparatedCommandAndOutput
            && !(expandedText?.isEmpty ?? true)
        let outputColor = configuration.isError ? UIColor(Color.tokyoRed) : UIColor(Color.tokyoFg)
        if let expandedText, showLegacyExpanded {
            let presentation = Self.makeANSIOutputPresentation(
                expandedText,
                isError: configuration.isError
            )
            expandedLabel.attributedText = presentation.attributedText
            expandedLabel.text = presentation.plainText
            expandedLabel.textColor = outputColor
        } else {
            expandedLabel.attributedText = nil
            expandedLabel.text = nil
            expandedLabel.textColor = outputColor
        }
        expandedContainer.isHidden = !showLegacyExpanded

        let commandText = configuration.expandedCommandText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showCommand = configuration.isExpanded
            && configuration.showSeparatedCommandAndOutput
            && !(commandText?.isEmpty ?? true)
        if let commandText, showCommand {
            if commandText.utf8.count <= Self.maxShellHighlightBytes {
                commandLabel.attributedText = ToolTimelineRowContentView.shellHighlighted(commandText)
                commandLabel.textColor = UIColor(Color.tokyoFg)
            } else {
                commandLabel.attributedText = nil
                commandLabel.text = commandText
                commandLabel.textColor = UIColor(Color.tokyoFg)
            }
        } else {
            commandLabel.attributedText = nil
            commandLabel.text = nil
            commandLabel.textColor = UIColor(Color.tokyoFg)
        }
        commandContainer.isHidden = !showCommand

        let outputText = configuration.expandedOutputText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showOutput = configuration.isExpanded
            && configuration.showSeparatedCommandAndOutput
            && !(outputText?.isEmpty ?? true)
        if let outputText, showOutput {
            let presentation = Self.makeANSIOutputPresentation(
                outputText,
                isError: configuration.isError
            )
            outputLabel.attributedText = presentation.attributedText
            outputLabel.text = presentation.plainText
            outputLabel.textColor = outputColor
        } else {
            outputLabel.attributedText = nil
            outputLabel.text = nil
            outputLabel.textColor = outputColor
        }
        outputContainer.isHidden = !showOutput

        let showBody = showPreview || showLegacyExpanded || showCommand || showOutput
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody

        let symbolName: String
        let statusColor: UIColor
        if !configuration.isDone {
            symbolName = "play.circle.fill"
            statusColor = UIColor(Color.tokyoBlue)
        } else if configuration.isError {
            symbolName = "xmark.circle.fill"
            statusColor = UIColor(Color.tokyoRed)
        } else {
            symbolName = "checkmark.circle.fill"
            statusColor = UIColor(Color.tokyoGreen)
        }

        statusImageView.image = UIImage(systemName: symbolName)
        statusImageView.tintColor = statusColor

        if !configuration.isDone {
            borderView.backgroundColor = UIColor(Color.tokyoBgHighlight.opacity(0.75))
            borderView.layer.borderColor = UIColor(Color.tokyoBlue.opacity(0.25)).cgColor
        } else if configuration.isError {
            borderView.backgroundColor = UIColor(Color.tokyoRed.opacity(0.08))
            borderView.layer.borderColor = UIColor(Color.tokyoRed.opacity(0.25)).cgColor
        } else {
            borderView.backgroundColor = UIColor(Color.tokyoGreen.opacity(0.06))
            borderView.layer.borderColor = UIColor(Color.tokyoComment.opacity(0.2)).cgColor
        }
    }

    @objc private func ignoreTap() {
        // Intentionally empty: consumes single taps inside copy-target areas so
        // collection-view row selection does not interfere with copy gestures.
    }

    @objc private func handleCommandDoubleTap() {
        guard let text = commandCopyText else { return }
        copy(text: text, feedbackView: commandContainer)
    }

    @objc private func handleOutputDoubleTap() {
        guard let text = outputCopyText else { return }
        copy(text: text, feedbackView: outputContainer)
    }

    @objc private func handleExpandedDoubleTap() {
        guard let text = outputCopyText else { return }
        copy(text: text, feedbackView: expandedContainer)
    }

    private var commandCopyText: String? {
        let explicit = currentConfiguration.copyCommandText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        let fallback = currentConfiguration.expandedCommandText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty {
            return fallback
        }

        return nil
    }

    private var outputCopyText: String? {
        if let explicit = currentConfiguration.copyOutputText,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }

        if let separated = currentConfiguration.expandedOutputText,
           !separated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return separated
        }

        if let legacy = currentConfiguration.expandedText,
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return legacy
        }

        return nil
    }

    private func copy(text: String, feedbackView: UIView) {
        UIPasteboard.general.string = text

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.8)

        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            feedbackView.alpha = 0.78
        } completion: { _ in
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                feedbackView.alpha = 1
            }
        }
    }

    struct ANSIOutputPresentation {
        let attributedText: NSAttributedString?
        let plainText: String?
    }

    static func makeANSIOutputPresentation(
        _ text: String,
        isError: Bool,
        maxHighlightBytes: Int = maxANSIHighlightBytes
    ) -> ANSIOutputPresentation {
        if text.utf8.count <= maxHighlightBytes {
            return ANSIOutputPresentation(
                attributedText: ansiHighlighted(
                    text,
                    baseForeground: isError ? .tokyoRed : .tokyoFg
                ),
                plainText: nil
            )
        }

        return ANSIOutputPresentation(
            attributedText: nil,
            plainText: ANSIParser.strip(text)
        )
    }

    private static func shellHighlighted(_ text: String) -> NSAttributedString {
        let highlighted = SyntaxHighlighter.highlight(text, language: .shell)
        return NSAttributedString(highlighted)
    }

    private static func ansiHighlighted(
        _ text: String,
        baseForeground: Color = .tokyoFg
    ) -> NSAttributedString {
        let highlighted = ANSIParser.attributedString(from: text, baseForeground: baseForeground)
        return NSAttributedString(highlighted)
    }

    private static func styledTitle(
        title: String,
        toolNamePrefix: String?,
        toolNameColor: UIColor
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor(Color.tokyoFg),
            ]
        )

        guard let toolNamePrefix,
              !toolNamePrefix.isEmpty else {
            return base
        }

        let prefixLength = (toolNamePrefix as NSString).length
        guard prefixLength > 0 else { return base }

        let highlightRange: NSRange?
        if title.hasPrefix(toolNamePrefix) {
            highlightRange = NSRange(location: 0, length: prefixLength)
        } else {
            let nsTitle = title as NSString
            let spacedPrefix = "\(toolNamePrefix) "
            let range = nsTitle.range(of: spacedPrefix)
            highlightRange = range.location == NSNotFound
                ? nil
                : NSRange(location: range.location, length: prefixLength)
        }

        if let highlightRange {
            base.addAttribute(.foregroundColor, value: toolNameColor, range: highlightRange)
        }

        return base
    }
}

extension ToolTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let isCommandTarget = interaction.view === commandContainer
        let isOutputTarget = interaction.view === outputContainer || interaction.view === expandedContainer

        let command = commandCopyText
        let output = outputCopyText

        var actions: [UIMenuElement] = []

        if isCommandTarget, let command {
            actions.append(
                UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { [weak self] _ in
                    guard let self else { return }
                    self.copy(text: command, feedbackView: self.commandContainer)
                }
            )
            if let output {
                actions.append(
                    UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        guard let self else { return }
                        self.copy(text: output, feedbackView: self.commandContainer)
                    }
                )
            }
        } else if isOutputTarget, let output {
            actions.append(
                UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    guard let self else { return }
                    let feedbackView = interaction.view ?? self.outputContainer
                    self.copy(text: output, feedbackView: feedbackView)
                }
            )
            if let command {
                actions.append(
                    UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { [weak self] _ in
                        guard let self else { return }
                        let feedbackView = interaction.view ?? self.outputContainer
                        self.copy(text: command, feedbackView: feedbackView)
                    }
                )
            }
        }

        guard !actions.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: actions)
        }
    }
}
