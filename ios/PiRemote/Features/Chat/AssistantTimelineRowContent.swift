import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Handles both plain text and rich markdown (headings, lists, code blocks,
/// tables, inline formatting) via `AssistantMarkdownContentView`.
struct AssistantTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let isStreaming: Bool
    let canFork: Bool
    let onFork: (() -> Void)?
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        AssistantTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class AssistantTimelineRowContentView: UIView, UIContentView {
    private static let maxValidHeight: CGFloat = 10_000

    private let iconLabel = UILabel()
    private let markdownView = AssistantMarkdownContentView()

    private var currentConfiguration: AssistantTimelineRowConfiguration

    init(configuration: AssistantTimelineRowConfiguration) {
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
            guard let config = newValue as? AssistantTimelineRowConfiguration else { return }
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

        let fallbackWidth = targetSize.width.isFinite ? targetSize.width : bounds.width
        let width = fitted.width.isFinite && fitted.width > 0 ? fitted.width : max(1, fallbackWidth)

        let rawHeight: CGFloat
        if fitted.height.isFinite && fitted.height > 0 {
            rawHeight = fitted.height
        } else {
            rawHeight = 44
        }

        return CGSize(width: width, height: min(rawHeight, Self.maxValidHeight))
    }

    private func setupViews() {
        backgroundColor = .clear

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        iconLabel.textColor = UIColor(ThemeID.tokyoNight.palette.purple)
        iconLabel.text = "π"
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)
        iconLabel.isUserInteractionEnabled = true

        markdownView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(markdownView)
        iconLabel.addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            iconLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            markdownView.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 6),
            markdownView.topAnchor.constraint(equalTo: topAnchor),
            markdownView.trailingAnchor.constraint(equalTo: trailingAnchor),
            markdownView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconLabel.textColor = UIColor(palette.purple)

        markdownView.apply(configuration: .init(
            content: configuration.text,
            isStreaming: configuration.isStreaming,
            themeID: configuration.themeID
        ))
    }

    private func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UIPasteboard.general.string = trimmed
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.82)
    }
}

extension AssistantTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let text = currentConfiguration.text
        let hasCopyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasForkAction = currentConfiguration.canFork && currentConfiguration.onFork != nil

        guard hasCopyText || hasForkAction else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            var actions: [UIMenuElement] = []

            if hasCopyText {
                actions.append(
                    UIAction(title: "Copy Full Response", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        self?.copyToPasteboard(text)
                    }
                )

                actions.append(
                    UIAction(title: "Copy Full Response as Markdown", image: UIImage(systemName: "text.document")) { [weak self] _ in
                        self?.copyToPasteboard(text)
                    }
                )
            }

            if hasForkAction, let onFork = self.currentConfiguration.onFork {
                actions.append(
                    UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                        onFork()
                    }
                )
            }

            return UIMenu(title: "", children: actions)
        }
    }
}
