import SwiftUI
import UIKit

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var decodeTasks: [Task<Void, Never>] = []
    private var renderGeneration = 0
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        themeID: ThemeID
    ) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(isError)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        cancelDecodeTasks()
        clearRows()

        let palette = themeID.palette
        let parsed = NativeExpandedReadMediaParser.parse(output)

        if let filePath, !filePath.isEmpty {
            let pathLabel = UILabel()
            pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            pathLabel.textColor = UIColor(palette.comment)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.text = filePath.shortenedPath
            rootStack.addArrangedSubview(pathLabel)
        }

        if !parsed.strippedText.isEmpty {
            let textLabel = UILabel()
            textLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textLabel.textColor = UIColor(isError ? palette.red : palette.fg)
            textLabel.numberOfLines = 0
            textLabel.text = String(parsed.strippedText.prefix(3_000))
            rootStack.addArrangedSubview(makeCardView(contentView: textLabel, palette: palette))
        }

        if !parsed.images.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Images (\(parsed.images.count))"
            rootStack.addArrangedSubview(countLabel)

            let visibleImages = parsed.images.prefix(4)
            for image in visibleImages {
                rootStack.addArrangedSubview(makeImageCard(image: image, palette: palette))
            }
            if parsed.images.count > visibleImages.count {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.images.count - visibleImages.count) more image attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if !parsed.audio.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Audio (\(parsed.audio.count))"
            rootStack.addArrangedSubview(countLabel)

            for (index, clip) in parsed.audio.prefix(6).enumerated() {
                let row = UILabel()
                row.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = "🔊 Clip \(index + 1) • \(clip.mimeType ?? "audio/unknown")"
                rootStack.addArrangedSubview(makeCardView(contentView: row, palette: palette))
            }
            if parsed.audio.count > 6 {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.audio.count - 6) more audio attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if parsed.strippedText.isEmpty && parsed.images.isEmpty && parsed.audio.isEmpty {
            let empty = UILabel()
            empty.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            empty.textColor = UIColor(palette.comment)
            empty.numberOfLines = 0
            empty.text = "No readable media output"
            rootStack.addArrangedSubview(makeCardView(contentView: empty, palette: palette))
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeCardView(contentView: UIView, palette: ThemePalette) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    private func makeImageCard(image: ImageExtractor.ExtractedImage, palette: ThemePalette) -> UIView {
        let card = TappableImageCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.cornerRadius = 8
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 180),
        ])

        card.configure(placeholderColor: UIColor(palette.comment))

        let generation = renderGeneration
        let base64 = image.base64
        let task = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.renderGeneration == generation else {
                return
            }

            card.setDecodedImage(decoded)
        }

        decodeTasks.append(task)
        return card
    }

    private func clearRows() {
        renderGeneration += 1
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func cancelDecodeTasks() {
        for task in decodeTasks {
            task.cancel()
        }
        decodeTasks.removeAll(keepingCapacity: false)
    }
}

/// Interactive image card with tap-to-fullscreen and context menu (Copy/Save/Share).
///
/// Used by `NativeExpandedReadMediaView` for expanded image cards and designed
/// to be self-contained — handles its own gestures and modal presentation.
private final class TappableImageCard: UIView, UIContextMenuInteractionDelegate {
    private let cardImageView = UIImageView()
    private let placeholderLabel = UILabel()
    private(set) var decodedImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(placeholderColor: UIColor) {
        cardImageView.translatesAutoresizingMaskIntoConstraints = false
        cardImageView.contentMode = .scaleAspectFit
        cardImageView.clipsToBounds = true
        addSubview(cardImageView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.text = "Decoding image…"
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            cardImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardImageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @MainActor
    func setDecodedImage(_ image: UIImage?) {
        decodedImage = image
        if let image {
            cardImageView.image = image
            placeholderLabel.isHidden = true
        } else {
            placeholderLabel.text = "Image preview unavailable"
            placeholderLabel.isHidden = false
        }
    }

    @objc private func handleTap() {
        guard let image = decodedImage else { return }
        presentFullScreenImage(image)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        guard let presenter = nearestViewController() else { return }
        let controller = FullScreenImageViewController(image: image)
        // Use .overFullScreen — see ToolTimelineRowContentView.showFullScreenContent() comment.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let image = decodedImage else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: [
                UIAction(
                    title: "View Full Screen",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { _ in
                    self?.presentFullScreenImage(image)
                },
                UIAction(
                    title: "Copy Image",
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.image = image
                },
                UIAction(
                    title: "Save to Photos",
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    PhotoLibrarySaver.save(image)
                },
            ])
        }
    }
}

private struct NativeExpandedReadMediaParsed {
    let strippedText: String
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
}

private enum NativeExpandedReadMediaParser {
    static func parse(_ output: String) -> NativeExpandedReadMediaParsed {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return NativeExpandedReadMediaParsed(
            strippedText: strippedText,
            images: images,
            audio: audio
        )
    }
}
