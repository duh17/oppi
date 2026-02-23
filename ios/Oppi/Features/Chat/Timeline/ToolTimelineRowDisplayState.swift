import SwiftUI
import UIKit

@MainActor
enum ToolTimelineRowDisplayState {
    static func applyTitle(
        configuration: ToolTimelineRowConfiguration,
        titleLabel: UILabel
    ) {
        if let segmentTitle = configuration.segmentAttributedTitle {
            titleLabel.attributedText = segmentTitle
        } else {
            titleLabel.attributedText = ToolRowTextRenderer.styledTitle(
                title: configuration.title,
                toolNamePrefix: configuration.toolNamePrefix,
                toolNameColor: configuration.toolNameColor
            )
        }

        titleLabel.lineBreakMode = configuration.titleLineBreakMode
        if configuration.isExpanded {
            titleLabel.numberOfLines = configuration.titleLineBreakMode == .byTruncatingMiddle ? 1 : 3
        } else {
            titleLabel.numberOfLines = 1
        }
    }

    static func applyLanguageBadge(
        badge: String?,
        languageBadgeIconView: UIImageView
    ) {
        let trimmedBadge = badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let badgeSymbolName = ToolTimelineRowUIHelpers.languageBadgeSymbolName(for: trimmedBadge),
           let badgeImage = UIImage(systemName: badgeSymbolName) {
            languageBadgeIconView.image = badgeImage
            languageBadgeIconView.isHidden = false
        } else {
            languageBadgeIconView.image = nil
            languageBadgeIconView.isHidden = true
        }
    }

    static func applyTrailing(
        configuration: ToolTimelineRowConfiguration,
        addedLabel: UILabel,
        removedLabel: UILabel,
        trailingLabel: UILabel
    ) {
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

            if let segmentTrailing = configuration.segmentAttributedTrailing {
                trailingLabel.attributedText = segmentTrailing
                trailingLabel.isHidden = false
            } else {
                trailingLabel.attributedText = nil
                trailingLabel.text = configuration.trailing
                trailingLabel.isHidden = configuration.trailing == nil
            }
        }
    }

    static func updateTrailingVisibility(
        trailingStack: UIStackView,
        languageBadgeIconView: UIImageView,
        addedLabel: UILabel,
        removedLabel: UILabel,
        trailingLabel: UILabel
    ) {
        trailingStack.isHidden = languageBadgeIconView.isHidden
            && addedLabel.isHidden
            && removedLabel.isHidden
            && trailingLabel.isHidden
    }

    @discardableResult
    static func applyPreview(
        configuration: ToolTimelineRowConfiguration,
        previewLabel: UILabel
    ) -> Bool {
        let preview = configuration.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showPreview = !configuration.isExpanded && !(preview?.isEmpty ?? true)
        previewLabel.text = preview
        previewLabel.isHidden = !showPreview
        return showPreview
    }

    static func resetCommandState(
        commandLabel: UILabel,
        commandRenderSignature: inout Int?
    ) {
        commandLabel.attributedText = nil
        commandLabel.text = nil
        commandLabel.textColor = UIColor(Color.themeFg)
        commandRenderSignature = nil
    }

    static func resetOutputState(
        outputLabel: UILabel,
        outputScrollView: UIScrollView,
        outputViewportHeightConstraint: NSLayoutConstraint?,
        outputColor: UIColor,
        outputUsesUnwrappedLayout: inout Bool,
        outputRenderedText: inout String?,
        outputRenderSignature: inout Int?,
        outputUsesViewport: inout Bool,
        outputShouldAutoFollow: inout Bool
    ) {
        outputLabel.attributedText = nil
        outputLabel.text = nil
        outputLabel.textColor = outputColor
        outputLabel.lineBreakMode = .byCharWrapping
        outputScrollView.alwaysBounceHorizontal = false
        outputScrollView.showsHorizontalScrollIndicator = false
        outputUsesUnwrappedLayout = false
        outputRenderedText = nil
        outputRenderSignature = nil
        outputViewportHeightConstraint?.isActive = false
        outputUsesViewport = false
        outputShouldAutoFollow = true
        ToolTimelineRowUIHelpers.resetScrollPosition(outputScrollView)
    }

    static func applyContainerVisibility(
        _ container: UIView,
        shouldShow: Bool,
        isExpandingTransition: Bool,
        wasVisible: Bool
    ) {
        container.isHidden = !shouldShow
        if shouldShow {
            ToolTimelineRowPresentationHelpers.animateInPlaceReveal(
                container,
                shouldAnimate: isExpandingTransition && !wasVisible
            )
        } else {
            ToolTimelineRowPresentationHelpers.resetRevealAppearance(container)
        }
    }

    static func applyStatusAppearance(
        isDone: Bool,
        isError: Bool,
        statusImageView: UIImageView,
        borderView: UIView
    ) {
        let statusAppearance = ToolTimelineRowStatusAppearance.make(
            isDone: isDone,
            isError: isError
        )

        statusImageView.image = UIImage(systemName: statusAppearance.symbolName)
        statusImageView.tintColor = statusAppearance.statusColor
        borderView.backgroundColor = statusAppearance.borderBackgroundColor
        borderView.layer.borderColor = statusAppearance.borderColor
    }
}
