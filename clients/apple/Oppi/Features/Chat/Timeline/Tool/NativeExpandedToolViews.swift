import CryptoKit
import UIKit
import SwiftUI

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var renderSignature: Int?
    private let maxInlineImagePixelSize: CGFloat = 1_600
    private var audioPlayer: AudioPlayerService?

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
        themeID: ThemeID,
        audioPlayer: AudioPlayerService?
    ) {
        self.audioPlayer = audioPlayer
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(isError)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(themeID.rawValue)
        if let audioPlayer {
            hasher.combine(ObjectIdentifier(audioPlayer).hashValue)
        }
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

        let isVoiceMessage = filePath == "Voice message"
        if isVoiceMessage, let clip = parsed.audio.first {
            let row = NativeVoiceMessageView()
            row.apply(
                id: "expanded-voice-\(clip.base64.prefix(24))",
                message: displayText,
                base64: clip.base64,
                mimeType: clip.mimeType,
                delivery: nil,
                audioPlayer: audioPlayer,
                palette: palette
            )
            rootStack.addArrangedSubview(row)
            return
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
                let row = NativeExpandedAudioAttachmentView()
                row.apply(
                    id: "expanded-audio-\(index)-\(clip.base64.prefix(24))",
                    title: filePath?.isEmpty == false ? filePath ?? "Audio" : "Audio clip \(index + 1)",
                    base64: clip.base64,
                    mimeType: clip.mimeType,
                    audioPlayer: audioPlayer,
                    palette: palette,
                    compact: false
                )
                rootStack.addArrangedSubview(row)
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

@MainActor
final class NativeExpandedAudioAttachmentView: UIView {
    private static let maxDecodedBytes = 10 * 1024 * 1024

    private let container = UIView()
    private let rootStack = UIStackView()
    private let iconView = UIImageView(image: UIImage(systemName: "waveform"))
    private let labelsStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var id: String?
    private var fileURL: URL?
    private var audioPlayer: AudioPlayerService?
    private var decodeTask: Task<Void, Never>?
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        decodeTask?.cancel()
        if let audioStateObserver {
            NotificationCenter.default.removeObserver(audioStateObserver)
        }
    }

    func apply(
        id: String,
        title: String,
        base64: String,
        mimeType: String?,
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette,
        compact: Bool = false
    ) {
        self.id = id
        self.audioPlayer = audioPlayer
        self.fileURL = nil
        bindAudioStateObservationIfNeeded()

        titleLabel.text = title
        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.numberOfLines = compact ? 0 : 1
        titleLabel.lineBreakMode = compact ? .byWordWrapping : .byTruncatingMiddle
        subtitleLabel.isHidden = compact
        subtitleLabel.textColor = UIColor(palette.comment)
        iconView.tintColor = UIColor(palette.purple)
        spinner.color = UIColor(palette.purple)
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        guard mimeType?.lowercased() == "audio/wav" else {
            subtitleLabel.text = "Unsupported audio type: \(mimeType ?? "audio/unknown")"
            playButton.isEnabled = false
            updateButton(palette: palette)
            return
        }

        let compactBase64 = base64.filter { !$0.isWhitespace }
        guard estimatedDecodedByteCount(compactBase64) <= Self.maxDecodedBytes else {
            subtitleLabel.text = "Audio is over 10 MB and was not decoded"
            playButton.isEnabled = false
            updateButton(palette: palette)
            return
        }

        subtitleLabel.text = "Preparing WAV…"
        playButton.isEnabled = false
        updateButton(palette: palette)
        decodeTask?.cancel()
        let hasAudioPlayer = audioPlayer != nil
        let maxDecodedBytes = Self.maxDecodedBytes
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try ToolAudioAttachmentCache.cachedWAVFileURL(base64: compactBase64, maxDecodedBytes: maxDecodedBytes) }
            await MainActor.run { [weak self] in
                guard let self, self.id == id else { return }
                switch result {
                case .success(let url):
                    self.fileURL = url
                    let byteCount = (try? Data(contentsOf: url))?.count ?? 0
                    self.subtitleLabel.text = compact ? nil : "WAV • \(ToolCallFormatting.formatBytes(byteCount))"
                    self.playButton.isEnabled = hasAudioPlayer
                case .failure:
                    self.subtitleLabel.text = "Unable to decode WAV payload"
                    self.playButton.isEnabled = false
                }
                self.updateButton(palette: palette)
                ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            }
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 10

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = 2

        titleLabel.font = ToolFont.regular
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = ToolFont.small
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        addSubview(container)
        container.addSubview(rootStack)
        playButton.addSubview(spinner)
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)
        rootStack.addArrangedSubview(iconView)
        rootStack.addArrangedSubview(labelsStack)
        rootStack.addArrangedSubview(UIView())
        rootStack.addArrangedSubview(playButton)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
    }

    private func bindAudioStateObservationIfNeeded() {
        guard audioStateObserver == nil else { return }
        audioStateObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayerService.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateButton(palette: ThemeRuntimeState.currentPalette())
        }
    }

    private func updateButton(palette: ThemePalette) {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        playButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        guard let id else { return }

        if audioPlayer?.loadingItemID == id {
            playButton.setImage(nil, for: .normal)
            spinner.startAnimating()
        } else if audioPlayer?.playingItemID == id {
            spinner.stopAnimating()
            playButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        } else {
            spinner.stopAnimating()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        }
        playButton.tintColor = audioPlayer?.playingItemID == id ? UIColor(palette.purple) : UIColor(palette.comment)
    }

    @objc private func togglePlayback() {
        guard let id, let fileURL, let audioPlayer else { return }
        audioPlayer.toggleFilePlayback(fileURL: fileURL, itemID: id)
        updateButton(palette: ThemeRuntimeState.currentPalette())
    }

    private func estimatedDecodedByteCount(_ base64: String) -> Int {
        max(0, (base64.count * 3) / 4 - base64.suffix(2).filter { $0 == "=" }.count)
    }
}

private enum ToolAudioAttachmentCache {
    static func cachedWAVFileURL(base64: String, maxDecodedBytes: Int) throws -> URL {
        let digest = SHA256.hash(data: Data(base64.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = try cacheDirectory()
        let fileURL = directory.appendingPathComponent("tool-audio-\(digest).wav")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count <= maxDecodedBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OppiToolAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
