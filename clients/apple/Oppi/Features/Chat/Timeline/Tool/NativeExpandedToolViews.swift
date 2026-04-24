import UIKit
import SwiftUI

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var renderSignature: Int?
    private let maxInlineImagePixelSize: CGFloat = 1_600

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

        clearRows()

        let palette = themeID.palette
        let parsed = NativeExpandedReadMediaParser.parse(output)

        var displayText = parsed.strippedText
        var displayImages = parsed.images
        if displayImages.isEmpty,
           let rawSVG = displayText.data(using: .utf8),
           MediaMimeType.isSVGData(rawSVG) {
            displayImages = [ImageExtractor.ExtractedImage(
                base64: rawSVG.base64EncodedString(),
                mimeType: "image/svg+xml",
                range: displayText.startIndex..<displayText.endIndex
            )]
            displayText = ""
        }

        if let filePath, !filePath.isEmpty {
            let pathLabel = UILabel()
            pathLabel.font = ToolFont.small
            pathLabel.textColor = UIColor(palette.comment)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.text = filePath.shortenedPath
            rootStack.addArrangedSubview(pathLabel)
        }

        if !displayText.isEmpty {
            let textLabel = UILabel()
            textLabel.font = ToolFont.regular
            textLabel.textColor = UIColor(isError ? palette.red : palette.fg)
            textLabel.numberOfLines = 0
            textLabel.text = String(displayText.prefix(3_000))
            rootStack.addArrangedSubview(makeCardView(contentView: textLabel, palette: palette))
        }

        if !displayImages.isEmpty {
            let countLabel = UILabel()
            countLabel.font = ToolFont.smallBold
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = displayImages.count == 1 ? "Image" : "Images (\(displayImages.count))"
            rootStack.addArrangedSubview(countLabel)

            for image in displayImages.prefix(6) {
                let imageView = NativeExpandedInlineImageView(maxPixelSize: maxInlineImagePixelSize)
                imageView.apply(base64: image.base64, mimeType: image.mimeType)
                rootStack.addArrangedSubview(imageView)
            }
            if displayImages.count > 6 {
                let more = UILabel()
                more.font = ToolFont.small
                more.textColor = UIColor(palette.comment)
                more.text = "+\(displayImages.count - 6) more image attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if !parsed.audio.isEmpty {
            let countLabel = UILabel()
            countLabel.font = ToolFont.smallBold
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Audio (\(parsed.audio.count))"
            rootStack.addArrangedSubview(countLabel)

            for (index, clip) in parsed.audio.prefix(6).enumerated() {
                let row = UILabel()
                row.font = ToolFont.regular
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = "🔊 Clip \(index + 1) • \(clip.mimeType ?? "audio/unknown")"
                rootStack.addArrangedSubview(makeCardView(contentView: row, palette: palette))
            }
            if parsed.audio.count > 6 {
                let more = UILabel()
                more.font = ToolFont.small
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.audio.count - 6) more audio attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if displayText.isEmpty && displayImages.isEmpty && parsed.audio.isEmpty {
            let empty = UILabel()
            empty.font = ToolFont.regular
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

    private func clearRows() {
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

final class NativeExpandedInlineImageView: UIView {
    private let imageView = UIImageView()
    private let placeholder = UIActivityIndicatorView(style: .medium)
    private var aspectRatioConstraint: NSLayoutConstraint?
    private var decodeTask: Task<Void, Never>?
    private var decodedKey: String?
    private let maxPixelSize: CGFloat
    private var previewData: Data?
    private var previewMimeType: String?

    init(maxPixelSize: CGFloat) {
        self.maxPixelSize = maxPixelSize
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        decodeTask?.cancel()
    }

    private let animatedImageView = AnimatedImageWebContainerView()

    func apply(base64: String, mimeType: String?) {
        let key = ImageDecodeCache.decodeKey(for: base64, maxPixelSize: maxPixelSize)
        guard key != decodedKey else { return }
        decodedKey = key

        decodeTask?.cancel()
        imageView.image = nil
        imageView.isHidden = false
        animatedImageView.isHidden = true
        placeholder.isHidden = false
        placeholder.startAnimating()

        let maxPixelSize = self.maxPixelSize
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                await MainActor.run { [weak self] in
                    guard let self, self.decodedKey == key else { return }
                    self.applyDecodedImage(nil)
                }
                return
            }

            let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
            if info.prefersWebRenderer {
                let normalizedMimeType = info.normalizedMimeType ?? "image/gif"
                let dataURLString = "data:\(normalizedMimeType);base64,\(base64)"
                let aspectRatio = info.aspectRatio ?? MediaMimeType.extractSVGViewBoxAspectRatio(data)
                await MainActor.run { [weak self] in
                    guard let self, self.decodedKey == key else { return }
                    self.applyAnimatedImage(
                        dataURLString: dataURLString,
                        aspectRatio: aspectRatio,
                        data: data,
                        mimeType: normalizedMimeType
                    )
                }
                return
            }

            let image = ImageDecodeCache.decode(base64: base64, maxPixelSize: maxPixelSize)
            await MainActor.run { [weak self] in
                guard let self, self.decodedKey == key else { return }
                self.applyDecodedImage(image)
            }
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        animatedImageView.translatesAutoresizingMaskIntoConstraints = false
        animatedImageView.isHidden = true
        addSubview(animatedImageView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            animatedImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            animatedImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            animatedImageView.topAnchor.constraint(equalTo: topAnchor),
            animatedImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        imageView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        animatedImageView.addGestureRecognizer(doubleTap)
        animatedImageView.isUserInteractionEnabled = true
    }

    private func applyDecodedImage(_ image: UIImage?) {
        imageView.image = image
        imageView.isHidden = false
        animatedImageView.isHidden = true
        placeholder.stopAnimating()
        placeholder.isHidden = image != nil

        previewMimeType = nil
        previewData = nil

        aspectRatioConstraint?.isActive = false
        aspectRatioConstraint = nil

        guard let image, image.size.width > 0, image.size.height > 0 else {
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            return
        }
        let aspectRatio = image.size.height / image.size.width
        let constraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: aspectRatio)
        constraint.priority = .required
        constraint.isActive = true
        aspectRatioConstraint = constraint
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func applyAnimatedImage(
        dataURLString: String,
        aspectRatio: CGFloat?,
        data: Data,
        mimeType: String
    ) {
        imageView.image = nil
        imageView.isHidden = true
        animatedImageView.isHidden = false
        animatedImageView.apply(dataURLString: dataURLString)
        placeholder.stopAnimating()
        placeholder.isHidden = true

        previewData = data
        previewMimeType = mimeType

        aspectRatioConstraint?.isActive = false
        aspectRatioConstraint = nil

        if let aspectRatio, aspectRatio > 0 {
            let constraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / aspectRatio)
            constraint.priority = .required
            constraint.isActive = true
            aspectRatioConstraint = constraint
        }

        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        FullScreenImageViewController.present(image: image)
    }

    @objc private func handleDoubleTap() {
        guard let data = previewData,
              let mimeType = previewMimeType,
              let presenter = ToolTimelineRowPresentationHelpers.nearestViewController(from: self) else { return }

        let rootView = FullScreenMediaPreview(data: data, mimeType: mimeType)
        let controller = UIHostingController(rootView: rootView)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }
}

private struct FullScreenMediaPreview: View {
    let data: Data
    let mimeType: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                DataImagePreviewView(
                    data: data,
                    mimeType: mimeType,
                    maxPixelSize: 2_400,
                    maxHeight: nil,
                    allowsFullscreenStaticImage: true
                )
                .padding()
            }
            .background(Color.themeBg)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
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
