import UIKit

struct MessageQueueSurfaceConfiguration {
    let queue: MessageQueueState
    let onRemove: (String) async throws -> Void
    let onEditInComposer: () async throws -> Void
    var error: String? = nil

    var hasVisibleEntry: Bool { !queue.steering.isEmpty || !queue.followUp.isEmpty }
}

enum MessageQueueContainerPresentation {
    /// Its own Message Queue toggle over the list (the UI hang harness).
    case standalone
    /// The message-queue drawer of the extension strip, always expanded.
    case drawer
}

/// The queued steering and follow-up messages: each with its attachments and
/// a remove button, and Edit in composer for the whole queue. The messages sit
/// in a viewport capped like an extension drawer's, so a long report scrolls
/// inside it and the drawer's collapse button and Edit in composer stay on
/// screen. A double tap on a message opens it full screen, rendered.
final class MessageQueueView: UIView {
    private static let attachmentTileSize: CGFloat = 36

    /// Opens one queued message full screen. Nil leaves messages without a
    /// full-screen action.
    var onOpenMessage: ((MessageQueueItem) -> Void)?

    private let presentation: MessageQueueContainerPresentation
    private let stack = UIStackView()
    private let toggle = UIControl()
    private let toggleTitle = ExtensionChromeFont.label(.caption1, .semibold)
    private let toggleCount = ExtensionChromeFont.label(.caption2)
    private let toggleChevron = UIImageView()
    private let errorLabel = ExtensionChromeFont.label(.caption1, lines: 0)
    private let sections = UIStackView()
    private lazy var sectionsViewport = CappedScrollView(
        content: sections,
        maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight
    )
    private let editButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let editRow = UIStackView()
    private var configuration: MessageQueueSurfaceConfiguration?
    private var palette = ThemeRuntimeState.currentPalette()
    private var isExpanded = false
    private var isUpdating = false
    private var errorText: String?

    init(presentation: MessageQueueContainerPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let padding: CGFloat = presentation == .standalone ? 12 : 0
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])

        if presentation == .standalone {
            toggle.accessibilityIdentifier = "chat.messageQueue.toggle"
            toggle.isAccessibilityElement = true
            toggle.accessibilityTraits = .button
            toggleTitle.text = "Message Queue"
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let header = UIStackView(arrangedSubviews: [toggleTitle, spacer, toggleCount, toggleChevron])
            header.axis = .horizontal
            header.alignment = .center
            header.spacing = 8
            header.isUserInteractionEnabled = false
            header.translatesAutoresizingMaskIntoConstraints = false
            toggle.addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: toggle.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: toggle.trailingAnchor),
                header.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
                header.topAnchor.constraint(greaterThanOrEqualTo: toggle.topAnchor),
                toggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            ])
            toggle.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                // A host that sizes this view from outside (SwiftUI) measures
                // it again; otherwise the capped list absorbs the squeeze.
                self.invalidateIntrinsicContentSize()
                UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseOut) {
                    self.isExpanded.toggle()
                    self.render()
                    self.superview?.layoutIfNeeded()
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(toggle)
        }
        errorLabel.accessibilityIdentifier = "chat.messageQueue.error"
        stack.addArrangedSubview(errorLabel)
        sections.axis = .vertical
        sections.alignment = .fill
        sections.spacing = 8
        sectionsViewport.scrollView.accessibilityIdentifier = "chat.messageQueue.list"
        stack.addArrangedSubview(sectionsViewport)

        editButton.accessibilityIdentifier = "chat.messageQueue.editInComposer"
        editButton.titleLabel?.font = UIFont.scaled(.caption1, .semibold)
        editButton.titleLabel?.adjustsFontForContentSizeCategory = true
        editButton.setTitle("Edit in composer", for: .normal)
        editButton.addAction(UIAction { [weak self] _ in
            guard let configuration = self?.configuration else { return }
            self?.run { try await configuration.onEditInComposer() }
        }, for: .touchUpInside)
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        spinner.hidesWhenStopped = true
        editRow.axis = .horizontal
        editRow.alignment = .center
        editRow.spacing = 8
        editRow.addArrangedSubview(editButton)
        editRow.addArrangedSubview(spinner)
        editRow.addArrangedSubview(UIView())
        stack.addArrangedSubview(editRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Rebuilds the rows only when the queue, its error, or the theme changed;
    /// the actions always take the newest configuration.
    func apply(_ configuration: MessageQueueSurfaceConfiguration, themeID: ThemeID) {
        let shown = Shown(queue: configuration.queue, error: configuration.error, themeID: themeID)
        self.configuration = configuration
        guard shown != self.shown else { return }
        self.shown = shown
        palette = themeID.palette
        render()
    }

    private struct Shown: Equatable {
        let queue: MessageQueueState
        let error: String?
        let themeID: ThemeID
    }

    private var shown: Shown?

    private func render() {
        guard let configuration else { return }
        if presentation == .standalone {
            let count = MessageQueueAttachmentPresentation.countSubtitle(
                steeringCount: configuration.queue.steering.count,
                followUpCount: configuration.queue.followUp.count
            )
            toggleTitle.textColor = UIColor(palette.fg)
            toggleCount.text = count
            toggleCount.textColor = UIColor(palette.fg)
            toggleChevron.image = UIImage(
                systemName: isExpanded ? "chevron.down" : "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(font: UIFont.scaled(.body))
            )
            toggleChevron.tintColor = UIColor(palette.fg)
            toggle.accessibilityLabel = "Message Queue"
            toggle.accessibilityValue = count
        }
        let error = configuration.error ?? errorText
        errorLabel.text = error
        errorLabel.textColor = UIColor(palette.red)
        errorLabel.isHidden = error == nil

        let expanded = presentation == .drawer || isExpanded
        sectionsViewport.isHidden = !expanded
        editRow.isHidden = !expanded
        for view in sections.arrangedSubviews { view.removeFromSuperview() }
        if expanded {
            addSection("Steering", items: configuration.queue.steering)
            addSection("Follow-up", items: configuration.queue.followUp)
        }
        editButton.isEnabled = !isUpdating && configuration.hasVisibleEntry
        editButton.tintColor = UIColor(palette.blue)
        if isUpdating { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func addSection(_ title: String, items: [MessageQueueItem]) {
        guard !items.isEmpty else { return }
        let header = ExtensionChromeFont.label(.caption1, .semibold)
        header.text = title
        header.textColor = UIColor(palette.comment)
        sections.addArrangedSubview(header)
        for item in items {
            sections.addArrangedSubview(row(item))
        }
    }

    private func row(_ item: MessageQueueItem) -> UIView {
        let message = ExtensionChromeFont.label(.caption1, lines: 0)
        message.text = item.message
        message.textColor = UIColor(palette.fg)
        let body = UIStackView(arrangedSubviews: [message])
        body.axis = .vertical
        body.spacing = 6
        let chips = MessageQueueAttachmentPresentation.visibleAttachments(for: item)
        if !chips.isEmpty {
            body.addArrangedSubview(attachmentStrip(chips))
        }
        let well = UIView()
        well.backgroundColor = UIColor(palette.bg.opacity(0.30))
        well.layer.cornerRadius = 10
        if let onOpenMessage, !item.message.isEmpty {
            well.addGestureRecognizer(DoubleTapRecognizer { onOpenMessage(item) })
            message.accessibilityIdentifier = "chat.messageQueue.message.\(item.id)"
            message.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Open Full Screen") { _ in
                    onOpenMessage(item)
                    return true
                },
            ]
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: well.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -8),
            body.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
        ])

        let remove = UIButton(type: .custom)
        remove.setImage(UIImage(systemName: "trash"), for: .normal)
        remove.tintColor = UIColor(palette.comment)
        remove.isEnabled = !isUpdating
        remove.accessibilityLabel = "Remove queued message"
        remove.accessibilityIdentifier = "chat.messageQueue.remove.\(item.id)"
        let id = item.id
        remove.addAction(UIAction { [weak self] _ in
            guard let configuration = self?.configuration else { return }
            self?.run { try await configuration.onRemove(id) }
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 45),
            remove.heightAnchor.constraint(equalToConstant: 45),
        ])
        let row = UIStackView(arrangedSubviews: [well, remove])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private func attachmentStrip(_ chips: [MessageQueueVisibleAttachment]) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.attachmentTileSize),
        ])
        for chip in chips {
            switch chip {
            case .photo(let id, let name, let image):
                row.addArrangedSubview(photoThumb(id: id, name: name, image: image))
            case .file(let id, let name):
                row.addArrangedSubview(filePill(id: id, name: name))
            }
        }
        return scroll
    }

    private func photoThumb(id: String, name: String, image: ImageAttachment?) -> UIView {
        let tile = UIImageView()
        tile.contentMode = .scaleAspectFill
        tile.clipsToBounds = true
        tile.layer.cornerRadius = 8
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 1
        tile.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.3).cgColor
        if let image,
           let data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters),
           let decoded = UIImage(data: data) {
            tile.image = decoded
        } else {
            tile.backgroundColor = UIColor(palette.bg.opacity(0.30))
            tile.contentMode = .center
            tile.image = UIImage.scaledSymbol("photo", style: .caption1, weight: .semibold, color: UIColor(palette.comment))
        }
        tile.isAccessibilityElement = true
        tile.accessibilityIdentifier = "chat.messageQueue.attachment.\(id)"
        tile.accessibilityLabel = "Photo \(name)"
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Self.attachmentTileSize),
            tile.heightAnchor.constraint(equalToConstant: Self.attachmentTileSize),
        ])
        return tile
    }

    private func filePill(id: String, name: String) -> UIView {
        let icon = UIImageView(image: FileIcon.forPath(name).uiImage(pointSize: 12))
        icon.contentMode = .scaleAspectFit
        let label = UILabel()
        label.font = UIFont.scaledMonospaced(.caption2, .regular)
        label.adjustsFontForContentSizeCategory = true
        label.text = name
        label.textColor = UIColor(palette.fg)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        row.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.1)
        row.layer.cornerRadius = 10
        row.isAccessibilityElement = true
        row.accessibilityIdentifier = "chat.messageQueue.attachment.\(id)"
        row.accessibilityLabel = "Attachment \(name)"
        return row
    }

    /// A double tap that runs its closure; the row it sits on is rebuilt, not
    /// reconfigured, so the closure never goes stale.
    private final class DoubleTapRecognizer: UITapGestureRecognizer {
        private let action: () -> Void

        init(_ action: @escaping () -> Void) {
            self.action = action
            super.init(target: nil, action: nil)
            numberOfTapsRequired = 2
            addTarget(self, action: #selector(fire))
        }

        @objc private func fire() { action() }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isUpdating else { return }
        isUpdating = true
        errorText = nil
        render()
        Task { @MainActor [weak self] in
            do {
                try await operation()
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.isUpdating = false
            self?.render()
        }
    }
}
