import UIKit

/// Native UIKit user row — handles both text-only and image-bearing messages.
struct UserTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let images: [ImageAttachment]
    let canFork: Bool
    let onFork: (() -> Void)?
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        UserTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class UserTimelineRowContentView: UIView, UIContentView {
    private let outerStack = UIStackView()
    private let bubbleContainer = UIView()
    private let textRow = UIStackView()
    private let iconLabel = UILabel()
    private let messageLabel = UILabel()
    private let imageStrip = UIScrollView()
    private let imageStack = UIStackView()

    private static let thumbnailSize: CGFloat = 80
    private static let thumbnailCornerRadius: CGFloat = 8

    private var currentConfiguration: UserTimelineRowConfiguration
    private var decodeTasks: [Task<Void, Never>] = []
    private var thumbnailViews: [UIView] = []

    private lazy var bubbleDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBubbleDoubleTapCopy))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    init(configuration: UserTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? UserTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear

        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.alignment = .fill
        outerStack.spacing = 6

        // Image strip (horizontal scroll of thumbnails).
        imageStrip.translatesAutoresizingMaskIntoConstraints = false
        imageStrip.showsHorizontalScrollIndicator = false
        imageStrip.clipsToBounds = false

        imageStack.translatesAutoresizingMaskIntoConstraints = false
        imageStack.axis = .horizontal
        imageStack.spacing = 8
        imageStrip.addSubview(imageStack)

        NSLayoutConstraint.activate([
            imageStack.topAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.topAnchor),
            imageStack.leadingAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.leadingAnchor, constant: 24),
            imageStack.trailingAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.trailingAnchor),
            imageStack.bottomAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.bottomAnchor),
            imageStack.heightAnchor.constraint(equalTo: imageStrip.frameLayoutGuide.heightAnchor),
            imageStrip.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
        ])

        // Bubble container — subtle accent-tinted background.
        bubbleContainer.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.layer.cornerRadius = 10
        bubbleContainer.clipsToBounds = true
        bubbleContainer.addGestureRecognizer(bubbleDoubleTapGesture)

        // Text row (❯ + message).
        textRow.translatesAutoresizingMaskIntoConstraints = false
        textRow.axis = .horizontal
        textRow.alignment = .top
        textRow.spacing = 6

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.text = "❯"
        iconLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .body)

        textRow.addArrangedSubview(iconLabel)
        textRow.addArrangedSubview(messageLabel)

        bubbleContainer.addSubview(textRow)
        NSLayoutConstraint.activate([
            textRow.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 8),
            textRow.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 10),
            textRow.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -10),
            textRow.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -8),
        ])

        outerStack.addArrangedSubview(imageStrip)
        outerStack.addArrangedSubview(bubbleContainer)

        addSubview(outerStack)
        addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Apply

    private func apply(configuration: UserTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconLabel.textColor = UIColor(palette.blue)
        messageLabel.textColor = UIColor(palette.fg)

        // Subtle blue-tinted background — distinct from bgDark/bgHighlight
        // used by thinking traces and tool rows.
        bubbleContainer.backgroundColor = UIColor(palette.blue).withAlphaComponent(0.08)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)
        messageLabel.text = trimmedText
        messageLabel.isHidden = trimmedText.isEmpty
        bubbleContainer.isHidden = trimmedText.isEmpty && configuration.images.isEmpty
        iconLabel.isHidden = trimmedText.isEmpty && configuration.images.isEmpty

        // If text is empty but images exist, show just the ❯ prompt.
        if trimmedText.isEmpty && !configuration.images.isEmpty {
            iconLabel.isHidden = false
            textRow.isHidden = false
        }

        updateImageStrip(images: configuration.images, palette: palette)
    }

    // MARK: - Image strip

    private func updateImageStrip(images: [ImageAttachment], palette: ThemePalette) {
        // Cancel outstanding decodes.
        for task in decodeTasks { task.cancel() }
        decodeTasks.removeAll()

        // Clear previous thumbnails.
        for view in thumbnailViews {
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()

        imageStrip.isHidden = images.isEmpty
        guard !images.isEmpty else { return }

        let borderColor = UIColor(palette.comment).withAlphaComponent(0.3).cgColor

        for (index, attachment) in images.enumerated() {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.layer.cornerRadius = Self.thumbnailCornerRadius
            container.layer.borderWidth = 1
            container.layer.borderColor = borderColor
            container.clipsToBounds = true
            container.backgroundColor = UIColor(palette.bgHighlight)
            container.isAccessibilityElement = true
            container.accessibilityIdentifier = "chat.user.thumbnail.\(index)"
            container.accessibilityLabel = "Attached image \(index + 1)"

            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            container.addSubview(imageView)

            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
                container.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            // Tap to fullscreen.
            let tap = UITapGestureRecognizer(target: self, action: #selector(thumbnailTapped(_:)))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true

            imageStack.addArrangedSubview(container)
            thumbnailViews.append(container)

            // Async decode.
            let task = Task { [weak imageView] in
                let decoded = await Task.detached(priority: .userInitiated) {
                    guard let data = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters) else {
                        return nil as UIImage?
                    }
                    return UIImage(data: data)
                }.value
                guard !Task.isCancelled, let imageView else { return }
                imageView.image = decoded
            }
            decodeTasks.append(task)
        }
    }

    @objc private func thumbnailTapped(_ gesture: UITapGestureRecognizer) {
        guard let container = gesture.view,
              let imageView = container.subviews.compactMap({ $0 as? UIImageView }).first,
              let image = imageView.image else { return }

        presentFullScreenImage(image)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        guard let vc = findViewController() else { return }
        let zoomVC = FullScreenImageViewController(image: image)
        // Use .overFullScreen to prevent SwiftUI lifecycle churn (onDisappear/onAppear).
        zoomVC.modalPresentationStyle = .overFullScreen
        vc.present(zoomVC, animated: true)
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }

    @objc private func handleBubbleDoubleTapCopy() {
        let text = currentConfiguration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String) {
        TimelineCopyFeedback.copy(
            text,
            feedbackView: bubbleContainer,
            trimWhitespaceAndNewlines: true
        )
    }

    func contextMenu() -> UIMenu? {
        let text = currentConfiguration.text
        let images = currentConfiguration.images
        let hasCopyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasForkAction = currentConfiguration.canFork && currentConfiguration.onFork != nil

        guard hasCopyText || hasForkAction || !images.isEmpty else {
            return nil
        }

        var actions: [UIMenuElement] = []

        if hasCopyText {
            actions.append(
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copyToPasteboard(text)
                }
            )
        }

        if hasForkAction, let onFork = currentConfiguration.onFork {
            actions.append(
                UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                    onFork()
                }
            )
        }

        return UIMenu(title: "", children: actions)
    }
}

// MARK: - Context Menu

extension UserTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard contextMenu() != nil else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu()
        }
    }
}
