import SwiftUI
import UIKit

@MainActor
enum ToolTimelineRowViewStyler {
    static func styleBorderView(_ borderView: UIView) {
        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.layer.cornerRadius = 10
        borderView.layer.borderWidth = 1
    }

    static func styleHeader(
        statusImageView: UIImageView,
        toolImageView: UIImageView,
        titleLabel: UILabel,
        trailingStack: UIStackView,
        languageBadgeIconView: UIImageView,
        addedLabel: UILabel,
        removedLabel: UILabel,
        trailingLabel: UILabel
    ) {
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.contentMode = .scaleAspectFit

        toolImageView.translatesAutoresizingMaskIntoConstraints = false
        toolImageView.contentMode = .scaleAspectFit
        toolImageView.tintColor = UIColor(Color.themeCyan)
        toolImageView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(Color.themeFg)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 4
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)

        languageBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        languageBadgeIconView.contentMode = .scaleAspectFit
        languageBadgeIconView.tintColor = UIColor(Color.themeBlue)
        languageBadgeIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        languageBadgeIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        languageBadgeIconView.setContentHuggingPriority(.required, for: .horizontal)

        addedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        addedLabel.textColor = UIColor(Color.themeDiffAdded)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.setContentHuggingPriority(.required, for: .horizontal)

        removedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        removedLabel.textColor = UIColor(Color.themeDiffRemoved)
        removedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedLabel.setContentHuggingPriority(.required, for: .horizontal)

        trailingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trailingLabel.textColor = UIColor(Color.themeComment)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    static func stylePreviewLabel(_ previewLabel: UILabel) {
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = UIColor(Color.themeFgDim)
        previewLabel.numberOfLines = 3
    }

    static func styleCommand(
        commandContainer: UIView,
        commandLabel: UILabel
    ) {
        commandContainer.layer.cornerRadius = 6
        commandContainer.backgroundColor = UIColor(Color.themeBgHighlight.opacity(0.9))
        commandContainer.layer.borderWidth = 1
        commandContainer.layer.borderColor = UIColor(Color.themeBlue.opacity(0.35)).cgColor

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.numberOfLines = 0
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.textColor = UIColor(Color.themeFg)
    }

    static func styleOutput(
        outputContainer: UIView,
        outputScrollView: UIScrollView,
        outputLabel: UILabel,
        delegate: UIScrollViewDelegate
    ) {
        outputContainer.layer.cornerRadius = 6
        outputContainer.layer.masksToBounds = true
        outputContainer.backgroundColor = UIColor(Color.themeBgDark)
        outputContainer.layer.borderWidth = 1
        outputContainer.layer.borderColor = UIColor(Color.themeComment.opacity(0.2)).cgColor

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.alwaysBounceVertical = false
        outputScrollView.alwaysBounceHorizontal = false
        outputScrollView.showsVerticalScrollIndicator = true
        outputScrollView.showsHorizontalScrollIndicator = false
        outputScrollView.delegate = delegate

        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputLabel.numberOfLines = 0
        outputLabel.lineBreakMode = .byCharWrapping
        outputLabel.textColor = UIColor(Color.themeFg)
    }

    static func styleExpanded(
        expandedContainer: UIView,
        expandedScrollView: UIScrollView,
        expandedLabel: UILabel,
        expandedMarkdownView: AssistantMarkdownContentView,
        expandedReadMediaContainer: UIView,
        delegate: UIScrollViewDelegate
    ) {
        expandedContainer.layer.cornerRadius = 6
        expandedContainer.layer.masksToBounds = true
        expandedContainer.backgroundColor = UIColor(Color.themeBgDark.opacity(0.9))

        expandedScrollView.translatesAutoresizingMaskIntoConstraints = false
        expandedScrollView.alwaysBounceVertical = false
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsVerticalScrollIndicator = true
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedScrollView.delegate = delegate

        expandedLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        expandedLabel.numberOfLines = 0
        expandedLabel.lineBreakMode = .byCharWrapping

        expandedMarkdownView.translatesAutoresizingMaskIntoConstraints = false
        expandedMarkdownView.backgroundColor = .clear
        expandedMarkdownView.isHidden = true

        expandedReadMediaContainer.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.backgroundColor = .clear
        expandedReadMediaContainer.isHidden = true
    }

    static func styleImagePreview(
        imagePreviewContainer: UIView,
        imagePreviewImageView: UIImageView
    ) {
        imagePreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewContainer.backgroundColor = UIColor(Color.themeBgDark)
        imagePreviewContainer.layer.cornerRadius = 6
        imagePreviewContainer.layer.masksToBounds = true
        imagePreviewContainer.isHidden = true
        imagePreviewContainer.isUserInteractionEnabled = true

        imagePreviewImageView.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewImageView.contentMode = .scaleAspectFit
        imagePreviewImageView.clipsToBounds = true
    }

    static func styleExpandFloatingButton(_ expandFloatingButton: UIButton) {
        expandFloatingButton.translatesAutoresizingMaskIntoConstraints = false
        let expandBtnSymbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        expandFloatingButton.setImage(
            UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandBtnSymbolConfig),
            for: .normal
        )
        expandFloatingButton.tintColor = UIColor(Color.themeCyan)
        expandFloatingButton.backgroundColor = UIColor(Color.themeBgHighlight)
        expandFloatingButton.layer.cornerRadius = 18
        expandFloatingButton.layer.borderWidth = 1
        expandFloatingButton.layer.borderColor = UIColor(Color.themeComment.opacity(0.3)).cgColor
        expandFloatingButton.accessibilityIdentifier = "tool.expand-full-screen"
        expandFloatingButton.isHidden = true
    }

    static func styleBodyStack(_ bodyStack: UIStackView) -> NSLayoutConstraint {
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = 4
        return bodyStack.heightAnchor.constraint(equalToConstant: 0)
    }
}
