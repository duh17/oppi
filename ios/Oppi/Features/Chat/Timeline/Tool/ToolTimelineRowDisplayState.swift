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
        titleLabel.numberOfLines = 1
    }

    static func applyLanguageBadge(
        badge: String?,
        languageBadgeIconView: UIImageView
    ) {
        let trimmedBadge = badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let badgeImage = ToolTimelineRowUIHelpers.languageBadgeImage(for: trimmedBadge) {
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
        trailingLabel: UILabel,
        elapsedLabel: UILabel
    ) {
        trailingStack.isHidden = languageBadgeIconView.isHidden
            && addedLabel.isHidden
            && removedLabel.isHidden
            && trailingLabel.isHidden
            && elapsedLabel.isHidden
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

    /// Format elapsed seconds into a compact human-readable string.
    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        if m < 60 {
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }

    static func applyElapsed(
        startedAt: Date?,
        isDone: Bool,
        elapsedLabel: UILabel
    ) {
        guard let startedAt else {
            elapsedLabel.text = nil
            elapsedLabel.isHidden = true
            return
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        // Don't show for sub-second completed tools — too noisy
        if isDone && elapsed < 1 {
            elapsedLabel.text = nil
            elapsedLabel.isHidden = true
            return
        }

        elapsedLabel.text = formatElapsed(elapsed)
        elapsedLabel.isHidden = false
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
