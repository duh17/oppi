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
        trailingLabel: UILabel,
        elapsedLabel: UILabel
    ) {
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.contentMode = .scaleAspectFit

        toolImageView.translatesAutoresizingMaskIntoConstraints = false
        toolImageView.contentMode = .scaleAspectFit
        toolImageView.tintColor = UIColor(Color.themeCyan)
        toolImageView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ToolFont.title
        titleLabel.textColor = UIColor(Color.themeToolTitle)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

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

        elapsedLabel.font = ToolFont.small
        elapsedLabel.textColor = UIColor(Color.themeComment)
        elapsedLabel.numberOfLines = 1
        elapsedLabel.isHidden = true
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    static func stylePreviewLabel(_ previewLabel: UILabel) {
        previewLabel.font = ToolFont.regular
        previewLabel.textColor = UIColor(Color.themeToolOutput)
        previewLabel.numberOfLines = 3
    }

    /// Refresh fixed UIKit colors whenever a reusable row configuration is
    /// applied. SwiftUI invalidates the timeline for theme changes, but these
    /// UIKit views outlive a single body evaluation and must be recolored.
    static func applyChromeTheme(
        statusImageView: UIImageView,
        toolImageView: UIImageView,
        titleLabel: UILabel,
        languageBadgeIconView: UIImageView,
        addedLabel: UILabel,
        removedLabel: UILabel,
        trailingLabel: UILabel,
        elapsedLabel: UILabel
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        toolImageView.tintColor = UIColor(palette.cyan)
        titleLabel.textColor = UIColor(palette.toolTitle)
        languageBadgeIconView.tintColor = UIColor(palette.blue)
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)
        trailingLabel.textColor = UIColor(palette.comment)
        elapsedLabel.textColor = UIColor(palette.comment)
        // Status is assigned after rendering from the current configuration.
        statusImageView.tintColor = UIColor(palette.comment)
    }

    static func applyTheme(
        statusImageView: UIImageView,
        toolImageView: UIImageView,
        titleLabel: UILabel,
        languageBadgeIconView: UIImageView,
        addedLabel: UILabel,
        removedLabel: UILabel,
        trailingLabel: UILabel,
        elapsedLabel: UILabel,
        previewLabel: UILabel,
        expandedContainer: UIView
    ) {
        applyChromeTheme(
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )
        let palette = ThemeRuntimeState.currentPalette()
        previewLabel.textColor = UIColor(palette.toolOutput)
        expandedContainer.backgroundColor = UIColor(
            ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill
        )
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
        // Expanded body sits inline in the timeline row with no blur behind
        // it, so it takes the near-opaque card role. `applyTheme` refreshes the
        // fill when a reusable row crosses a live theme change.
        expandedContainer.backgroundColor = UIColor(ThemeSurfaceStyle.resolve(.opaqueCard).fill)

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
        expandedLabel.alwaysBounceVertical = false
        expandedLabel.bounces = false
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
        imagePreviewContainer.backgroundColor = .clear
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
        let collapsedHeight = bodyStack.heightAnchor.constraint(equalToConstant: 0)
        // When a reused/self-sizing cell is temporarily taller than its
        // collapsed content, let the hidden body absorb the slack instead of
        // stretching the one-line header label into a giant blank area.
        collapsedHeight.priority = .defaultHigh
        return collapsedHeight
    }
}
