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
        titleLabel.font = ToolFont.title
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
        languageBadgeIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        languageBadgeIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        languageBadgeIconView.setContentHuggingPriority(.required, for: .horizontal)
        // Size constraints are set by ToolTimelineRowLayoutBuilder.makeLanguageBadgeConstraints()

        addedLabel.font = ToolFont.regularBold
        addedLabel.textColor = UIColor(Color.themeDiffAdded)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.setContentHuggingPriority(.required, for: .horizontal)

        removedLabel.font = ToolFont.regularBold
        removedLabel.textColor = UIColor(Color.themeDiffRemoved)
        removedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedLabel.setContentHuggingPriority(.required, for: .horizontal)

        trailingLabel.font = ToolFont.regular
        trailingLabel.textColor = UIColor(Color.themeComment)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    static func stylePreviewLabel(_ previewLabel: UILabel) {
        previewLabel.font = ToolFont.regular
        previewLabel.textColor = UIColor(Color.themeFgDim)
        previewLabel.numberOfLines = 3
    }

    static func styleExpanded(
        expandedContainer: UIView,
        expandedScrollView: UIScrollView,
        expandedLabel: UITextView,
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
        expandedScrollView.bounces = false
        expandedScrollView.isDirectionalLockEnabled = true
        expandedScrollView.isScrollEnabled = false
        expandedScrollView.showsVerticalScrollIndicator = true
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedScrollView.delegate = delegate

        expandedLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedLabel.font = ToolFont.regular
        expandedLabel.isEditable = false
        expandedLabel.isScrollEnabled = false
        expandedLabel.isSelectable = false
        expandedLabel.textContainerInset = .zero
        expandedLabel.textContainer.lineFragmentPadding = 0
        expandedLabel.textContainer.lineBreakMode = .byCharWrapping
        expandedLabel.backgroundColor = .clear

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

    static func styleBodyStack(_ bodyStack: UIStackView) -> NSLayoutConstraint {
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = 4
        return bodyStack.heightAnchor.constraint(equalToConstant: 0)
    }
}
