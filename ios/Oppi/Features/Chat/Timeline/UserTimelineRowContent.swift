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
        let zoomVC = NativeZoomableImageViewController(image: image)
        zoomVC.modalPresentationStyle = .fullScreen
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
}

// MARK: - Context Menu

extension UserTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let text = currentConfiguration.text
        let images = currentConfiguration.images
        let hasCopyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasForkAction = currentConfiguration.canFork && currentConfiguration.onFork != nil

        guard hasCopyText || hasForkAction || !images.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            var actions: [UIMenuElement] = []

            if hasCopyText {
                actions.append(
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = text
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

// MARK: - Native Zoomable Image Viewer

/// Full-screen image viewer with pinch-to-zoom and double-tap.
///
/// Full-screen image viewer with pinch-to-zoom and double-tap.
final class NativeZoomableImageViewController: UIViewController {
    private let image: UIImage
    private var scrollView: UIScrollView!
    private var imageView: UIImageView!

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Pin all edges so contentLayoutGuide gets a deterministic content size
            // (equal to the viewport at zoomScale = 1). Center-only constraints can
            // leave content geometry underconstrained, causing the image to render
            // offset (top-left clipped) on first presentation.
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap to toggle zoom.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Done button.
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.setTitleColor(.white, for: .normal)
        done.translatesAutoresizingMaskIntoConstraints = false
        done.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(done)

        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            done.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
        ])
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    @objc private func dismissTapped() {
        dismiss(animated: true)
    }
}

extension NativeZoomableImageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}
