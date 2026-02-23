import UIKit

@MainActor
enum ToolTimelineRowLayoutBuilder {
    struct Constraints {
        let toolLeading: NSLayoutConstraint
        let toolWidth: NSLayoutConstraint
        let titleLeadingToStatus: NSLayoutConstraint
        let titleLeadingToTool: NSLayoutConstraint
        let outputLabelWidth: NSLayoutConstraint
        let expandedLabelWidth: NSLayoutConstraint
        let expandedMarkdownWidth: NSLayoutConstraint
        let expandedReadMediaWidth: NSLayoutConstraint
        let imagePreviewHeight: NSLayoutConstraint
        let outputViewportHeight: NSLayoutConstraint
        let expandedViewportHeight: NSLayoutConstraint
        let all: [NSLayoutConstraint]
    }

    static func makeLanguageBadgeConstraints(
        languageBadgeIconView: UIImageView
    ) -> [NSLayoutConstraint] {
        [
            languageBadgeIconView.widthAnchor.constraint(equalToConstant: 10),
            languageBadgeIconView.heightAnchor.constraint(equalToConstant: 10),
        ]
    }

    static func makeConstraints(
        containerView: UIView,
        borderView: UIView,
        statusImageView: UIImageView,
        toolImageView: UIImageView,
        titleLabel: UILabel,
        trailingStack: UIStackView,
        bodyStack: UIStackView,
        commandContainer: UIView,
        commandLabel: UILabel,
        outputContainer: UIView,
        outputScrollView: UIScrollView,
        outputLabel: UILabel,
        expandedContainer: UIView,
        expandedScrollView: UIScrollView,
        expandedLabel: UILabel,
        expandedMarkdownView: UIView,
        expandedReadMediaContainer: UIView,
        imagePreviewContainer: UIView,
        imagePreviewImageView: UIImageView,
        expandFloatingButton: UIButton,
        minOutputViewportHeight: CGFloat,
        minDiffViewportHeight: CGFloat,
        collapsedImagePreviewHeight: CGFloat
    ) -> Constraints {
        let toolLeading = toolImageView.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 0)
        let toolWidth = toolImageView.widthAnchor.constraint(equalToConstant: 0)
        let titleLeadingToStatus = titleLabel.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 5)
        let titleLeadingToTool = titleLabel.leadingAnchor.constraint(equalTo: toolImageView.trailingAnchor, constant: 5)

        let outputLabelWidth = outputLabel.widthAnchor.constraint(
            equalTo: outputScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let expandedLabelWidth = expandedLabel.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let expandedMarkdownWidth = expandedMarkdownView.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let expandedReadMediaWidth = expandedReadMediaContainer.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let imagePreviewHeight = imagePreviewContainer.heightAnchor.constraint(
            equalToConstant: collapsedImagePreviewHeight
        )

        let outputViewportHeight = outputContainer.heightAnchor.constraint(equalToConstant: minOutputViewportHeight)
        let expandedViewportHeight = expandedContainer.heightAnchor.constraint(equalToConstant: minDiffViewportHeight)

        let all: [NSLayoutConstraint] = [
            borderView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            borderView.topAnchor.constraint(equalTo: containerView.topAnchor),
            borderView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            statusImageView.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            statusImageView.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 6),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),

            toolLeading,
            toolImageView.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            toolWidth,
            toolImageView.heightAnchor.constraint(equalToConstant: 12),

            titleLeadingToStatus,
            titleLabel.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 6),

            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            trailingStack.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),

            bodyStack.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            bodyStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),
            bodyStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyStack.bottomAnchor.constraint(equalTo: borderView.bottomAnchor, constant: -6),

            commandLabel.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 6),
            commandLabel.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -6),
            commandLabel.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: 5),
            commandLabel.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -5),

            outputScrollView.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor),
            outputScrollView.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            outputScrollView.topAnchor.constraint(equalTo: outputContainer.topAnchor),
            outputScrollView.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor),

            outputLabel.leadingAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            outputLabel.trailingAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            outputLabel.topAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.topAnchor, constant: 5),
            outputLabel.bottomAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            outputLabelWidth,

            expandedScrollView.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            expandedScrollView.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            expandedScrollView.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            expandedScrollView.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),

            expandedLabel.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedLabel.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedLabel.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedLabel.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedLabelWidth,

            expandedMarkdownView.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedMarkdownView.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedMarkdownView.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedMarkdownView.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedMarkdownWidth,

            expandedReadMediaContainer.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedReadMediaContainer.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedReadMediaContainer.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedReadMediaContainer.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedReadMediaWidth,

            imagePreviewImageView.leadingAnchor.constraint(equalTo: imagePreviewContainer.leadingAnchor, constant: 6),
            imagePreviewImageView.trailingAnchor.constraint(equalTo: imagePreviewContainer.trailingAnchor, constant: -6),
            imagePreviewImageView.topAnchor.constraint(equalTo: imagePreviewContainer.topAnchor, constant: 6),
            imagePreviewImageView.bottomAnchor.constraint(equalTo: imagePreviewContainer.bottomAnchor, constant: -6),
            imagePreviewHeight,
            imagePreviewImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            expandFloatingButton.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -10),
            expandFloatingButton.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -10),
            expandFloatingButton.widthAnchor.constraint(equalToConstant: 36),
            expandFloatingButton.heightAnchor.constraint(equalToConstant: 36),
        ]

        return Constraints(
            toolLeading: toolLeading,
            toolWidth: toolWidth,
            titleLeadingToStatus: titleLeadingToStatus,
            titleLeadingToTool: titleLeadingToTool,
            outputLabelWidth: outputLabelWidth,
            expandedLabelWidth: expandedLabelWidth,
            expandedMarkdownWidth: expandedMarkdownWidth,
            expandedReadMediaWidth: expandedReadMediaWidth,
            imagePreviewHeight: imagePreviewHeight,
            outputViewportHeight: outputViewportHeight,
            expandedViewportHeight: expandedViewportHeight,
            all: all
        )
    }
}
