import AVKit
import CryptoKit
import UIKit
import SwiftUI

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var renderSignature: Int?
    private let maxInlineImagePixelSize: CGFloat = 1_600
    private let svgModeControl = UISegmentedControl(items: ["Preview", "Source"])
    private weak var svgPreviewToggleView: UIView?
    private weak var svgSourceToggleView: UIView?
    private var svgDisplayMode: SVGDisplayMode = .preview

    private enum SVGDisplayMode {
        case preview
        case source
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let targetWidth = max(1, targetSize.width > 0 ? targetSize.width : bounds.width)
        let stackSize = rootStack.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: targetWidth, height: max(1, ceil(stackSize.height)))
    }

    func apply(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment],
        themeID: ThemeID,
        audioPlayer: AudioPlayerService?,
        sessionId: String? = nil,
        attachmentFetcher: ((String) async throws -> Data)?,
        attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)? = nil,
        sessionFileDataFetcher: ((String) async throws -> Data)?,
        sessionFileMediaSourceProvider: ((String) async throws -> AuthenticatedMediaSource)?
    ) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(isError)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(sessionId ?? "")
        for attachment in attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.mimeType)
            hasher.combine(attachment.sizeBytes)
            hasher.combine(attachment.sha256)
            hasher.combine(attachment.width)
            hasher.combine(attachment.height)
        }
        hasher.combine(attachmentFetcher != nil)
        hasher.combine(attachmentMediaSourceProvider != nil)
        hasher.combine(sessionFileDataFetcher != nil)
        hasher.combine(sessionFileMediaSourceProvider != nil)
        hasher.combine(themeID.rawValue)
        if let audioPlayer {
            hasher.combine(ObjectIdentifier(audioPlayer).hashValue)
        }
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature
        svgDisplayMode = .preview

        clearRows()

        let palette = themeID.palette
        let parsed = NativeExpandedReadMediaParser.parse(output)

        var displayText = parsed.strippedText
        var displayImages = parsed.images
        let isSVGFile = filePath?.lowercased().hasSuffix(".svg") == true
        var svgSourceText: String?
        var shouldRenderFetchedSVG = false
        if displayImages.isEmpty,
           let rawSVG = displayText.data(using: .utf8),
           MediaMimeType.isSVGData(rawSVG) {
            svgSourceText = displayText
            if MediaMimeType.isCompleteSVGData(rawSVG) {
                displayImages = [ImageExtractor.ExtractedImage(
                    base64: rawSVG.base64EncodedString(),
                    mimeType: "image/svg+xml",
                    range: displayText.startIndex..<displayText.endIndex
                )]
                displayText = ""
            } else if isSVGFile, sessionFileDataFetcher != nil {
                shouldRenderFetchedSVG = true
                displayText = ""
            }
        } else if displayImages.isEmpty,
                  isSVGFile,
                  sessionFileDataFetcher != nil,
                  parsed.audio.isEmpty {
            shouldRenderFetchedSVG = true
            svgSourceText = displayText.isEmpty ? nil : displayText
            displayText = ""
        }

        let imageAttachments = attachments.filter { $0.kind == "image" }
        let videoAttachments = attachments.filter { attachment in
            attachment.kind == "video" || attachment.mimeType.lowercased().hasPrefix("video/")
        }
        let isVideoFile = filePath.map { path in
            if case .video = FileType.detect(from: path) { return true }
            return false
        } ?? false
        let hasVideoFileMediaSourceProvider = filePath != nil && sessionFileMediaSourceProvider != nil
        let shouldRenderFetchedVideo = isVideoFile && hasVideoFileMediaSourceProvider
        let hasRenderableImageAttachment = attachmentFetcher != nil && !imageAttachments.isEmpty
        let hasRenderableVideoAttachment = attachmentMediaSourceProvider != nil && !videoAttachments.isEmpty
        let hasRenderedImage = !displayImages.isEmpty || hasRenderableImageAttachment || shouldRenderFetchedSVG
        let hasRenderedVideo = shouldRenderFetchedVideo || hasRenderableVideoAttachment
        let hasImageReadBoilerplate = NativeExpandedReadMediaParser.containsImageReadBoilerplate(displayText)
        let hasVideoReadBoilerplate = NativeExpandedReadMediaParser.containsVideoReadBoilerplate(displayText)
        if hasRenderedImage {
            displayText = NativeExpandedReadMediaParser.removingRedundantImageReadBoilerplate(from: displayText)
        }
        if hasRenderedVideo {
            displayText = NativeExpandedReadMediaParser.removingRedundantVideoReadBoilerplate(from: displayText)
        }

        let isVoiceMessage = filePath == "Voice message"
        if isVoiceMessage, let clip = parsed.audio.first {
            let row = NativeAudioMessageView()
            row.apply(
                id: "expanded-voice-\(clip.base64.prefix(24))",
                message: displayText,
                base64: clip.base64,
                mimeType: clip.mimeType,
                playbackBehavior: nil,
                sessionId: nil,
                audioPlayer: audioPlayer,
                palette: palette,
                suppressAutoplay: true
            )
            rootStack.addArrangedSubview(row)
            return
        }

        let previewStack = makeVerticalStack()
        let sourceView = svgSourceText.map { makeSourceCard(source: $0, palette: palette) }
        let usesSVGToggle = sourceView != nil && hasRenderedImage
        let contentStack: UIStackView
        if usesSVGToggle {
            configureSVGModeControl(palette: palette)
            rootStack.addArrangedSubview(svgModeControl)
            rootStack.addArrangedSubview(previewStack)
            if let sourceView {
                rootStack.addArrangedSubview(sourceView)
                svgSourceToggleView = sourceView
            }
            svgPreviewToggleView = previewStack
            contentStack = previewStack
        } else {
            contentStack = rootStack
        }

        if let filePath, !filePath.isEmpty, !(hasRenderedImage && hasImageReadBoilerplate), !(hasRenderedVideo && hasVideoReadBoilerplate) {
            let pathLabel = UILabel()
            pathLabel.font = ToolFont.small
            pathLabel.textColor = UIColor(palette.comment)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.text = filePath.shortenedPath
            contentStack.addArrangedSubview(pathLabel)
        }

        if !displayText.isEmpty {
            let textLabel = UILabel()
            textLabel.font = ToolFont.regular
            textLabel.textColor = UIColor(isError ? palette.red : palette.fg)
            textLabel.numberOfLines = 0
            textLabel.text = String(displayText.prefix(3_000))
            contentStack.addArrangedSubview(makeCardView(contentView: textLabel, palette: palette))
        }

        let totalImageCount = displayImages.count + imageAttachments.count + (shouldRenderFetchedSVG ? 1 : 0)
        if totalImageCount > 0 {
            if totalImageCount > 1 || !displayText.isEmpty {
                let countLabel = UILabel()
                countLabel.font = ToolFont.smallBold
                countLabel.textColor = UIColor(palette.comment)
                countLabel.text = totalImageCount == 1 ? "Image" : "Images (\(totalImageCount))"
                contentStack.addArrangedSubview(countLabel)
            }

            var renderedCount = 0
            if shouldRenderFetchedSVG, let filePath {
                let imageView = NativeExpandedInlineImageView(maxPixelSize: maxInlineImagePixelSize)
                imageView.apply(filePath: filePath, mimeType: "image/svg+xml", fetcher: sessionFileDataFetcher)
                contentStack.addArrangedSubview(imageView)
                renderedCount += 1
            }
            for image in displayImages.prefix(6 - renderedCount) {
                let imageView = NativeExpandedInlineImageView(maxPixelSize: maxInlineImagePixelSize)
                imageView.apply(base64: image.base64, mimeType: image.mimeType)
                contentStack.addArrangedSubview(imageView)
                renderedCount += 1
            }
            if renderedCount < 6 {
                for attachment in imageAttachments.prefix(6 - renderedCount) {
                    let imageView = NativeExpandedInlineImageView(maxPixelSize: maxInlineImagePixelSize)
                    imageView.apply(attachment: attachment, fetcher: attachmentFetcher)
                    contentStack.addArrangedSubview(imageView)
                    renderedCount += 1
                }
            }
            if totalImageCount > renderedCount {
                let more = UILabel()
                more.font = ToolFont.small
                more.textColor = UIColor(palette.comment)
                more.text = "+\(totalImageCount - renderedCount) more image attachment(s)"
                contentStack.addArrangedSubview(more)
            }
        }

        let totalVideoCount = videoAttachments.count + (shouldRenderFetchedVideo ? 1 : 0)
        if totalVideoCount > 0 {
            let countLabel = UILabel()
            countLabel.font = ToolFont.smallBold
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = totalVideoCount == 1 ? "Video" : "Videos (\(totalVideoCount))"
            contentStack.addArrangedSubview(countLabel)

            var renderedCount = 0
            if shouldRenderFetchedVideo, let filePath {
                let row = NativeExpandedVideoAttachmentView()
                let pathExtension = (filePath as NSString).pathExtension
                let mimeType = MediaMimeType.videoMimeType(forPathExtension: pathExtension)
                row.apply(
                    id: "expanded-video-file-\(filePath)",
                    title: filePath.shortenedPath,
                    subtitle: NativeExpandedVideoAttachmentView.subtitle(mimeType: mimeType, sizeBytes: nil),
                    mimeType: mimeType,
                    sourceFileExtension: pathExtension,
                    mediaSourceProvider: sessionFileMediaSourceProvider.map { provider in { try await provider(filePath) } },
                    sessionId: sessionId,
                    palette: palette
                )
                contentStack.addArrangedSubview(row)
                renderedCount += 1
            }

            if renderedCount < 6, attachmentMediaSourceProvider != nil {
                for attachment in videoAttachments.prefix(6 - renderedCount) {
                    let row = NativeExpandedVideoAttachmentView()
                    let sourceFileExtension = attachment.fileName.map { ($0 as NSString).pathExtension }
                    row.apply(
                        id: "expanded-video-attachment-\(attachment.id)",
                        title: attachment.fileName?.isEmpty == false ? attachment.fileName ?? "Video" : "Video attachment",
                        subtitle: NativeExpandedVideoAttachmentView.subtitle(
                            mimeType: attachment.mimeType,
                            sizeBytes: attachment.sizeBytes
                        ),
                        mimeType: attachment.mimeType,
                        sourceFileExtension: sourceFileExtension,
                        mediaSourceProvider: attachmentMediaSourceProvider.map { provider in
                            { try await provider(attachment.id, attachment.mimeType, sourceFileExtension) }
                        },
                        sessionId: sessionId,
                        palette: palette
                    )
                    contentStack.addArrangedSubview(row)
                    renderedCount += 1
                }
            }

            if totalVideoCount > renderedCount {
                let more = UILabel()
                more.font = ToolFont.small
                more.textColor = UIColor(palette.comment)
                more.text = "+\(totalVideoCount - renderedCount) more video attachment(s)"
                contentStack.addArrangedSubview(more)
            }
        }

        if !parsed.audio.isEmpty {
            let countLabel = UILabel()
            countLabel.font = ToolFont.smallBold
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Audio (\(parsed.audio.count))"
            contentStack.addArrangedSubview(countLabel)

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
                contentStack.addArrangedSubview(row)
            }
            if parsed.audio.count > 6 {
                let more = UILabel()
                more.font = ToolFont.small
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.audio.count - 6) more audio attachment(s)"
                contentStack.addArrangedSubview(more)
            }
        }

        if displayText.isEmpty && displayImages.isEmpty && imageAttachments.isEmpty && videoAttachments.isEmpty && parsed.audio.isEmpty && !shouldRenderFetchedSVG && !shouldRenderFetchedVideo {
            let empty = UILabel()
            empty.font = ToolFont.regular
            empty.textColor = UIColor(palette.comment)
            empty.numberOfLines = 0
            empty.text = "No readable media output"
            contentStack.addArrangedSubview(makeCardView(contentView: empty, palette: palette))
        }

        updateSVGToggleVisibility()
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        svgModeControl.selectedSegmentIndex = 0
        svgModeControl.addTarget(self, action: #selector(svgModeChanged), for: .valueChanged)

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func makeVerticalStack() -> UIStackView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        return stack
    }

    private func configureSVGModeControl(palette: ThemePalette) {
        svgModeControl.selectedSegmentIndex = svgDisplayMode == .preview ? 0 : 1
        svgModeControl.selectedSegmentTintColor = UIColor(palette.bgHighlight)
        svgModeControl.backgroundColor = UIColor(palette.bgDark)
        svgModeControl.setTitleTextAttributes([
            .foregroundColor: UIColor(palette.comment),
            .font: ToolFont.smallBold,
        ], for: .normal)
        svgModeControl.setTitleTextAttributes([
            .foregroundColor: UIColor(palette.fg),
            .font: ToolFont.smallBold,
        ], for: .selected)
    }

    private func makeSourceCard(source: String, palette: ThemePalette) -> UIView {
        let label = UILabel()
        label.font = ToolFont.small
        label.textColor = UIColor(palette.fg)
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return makeCardView(contentView: label, palette: palette)
    }

    @objc private func svgModeChanged() {
        svgDisplayMode = svgModeControl.selectedSegmentIndex == 1 ? .source : .preview
        updateSVGToggleVisibility()
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func updateSVGToggleVisibility() {
        svgModeControl.selectedSegmentIndex = svgDisplayMode == .preview ? 0 : 1
        svgPreviewToggleView?.isHidden = svgDisplayMode == .source
        svgSourceToggleView?.isHidden = svgDisplayMode == .preview
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
        svgPreviewToggleView = nil
        svgSourceToggleView = nil
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

@MainActor
final class NativeExpandedVideoAttachmentView: UIView {
    private let container = UIView()
    private let rootStack = UIStackView()
    private let iconView = UIImageView(image: UIImage(systemName: "film"))
    private let labelsStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var id: String?
    private var mimeType: String?
    private var sourceFileExtension: String?
    private var mediaSourceProvider: (() async throws -> AuthenticatedMediaSource)?
    private var sessionId: String?
    private var fetchTask: Task<Void, Never>?
    private var lastError: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        fetchTask?.cancel()
    }

    func apply(
        id: String,
        title: String,
        subtitle: String,
        mimeType: String?,
        sourceFileExtension: String?,
        mediaSourceProvider: (() async throws -> AuthenticatedMediaSource)?,
        sessionId: String? = nil,
        palette: ThemePalette
    ) {
        if self.id != id {
            fetchTask?.cancel()
            lastError = nil
        }

        self.id = id
        self.mimeType = mimeType
        self.sourceFileExtension = sourceFileExtension
        self.mediaSourceProvider = mediaSourceProvider
        self.sessionId = sessionId

        accessibilityIdentifier = "toolRow.videoAttachment"
        titleLabel.accessibilityIdentifier = "toolRow.videoAttachment.title"
        subtitleLabel.accessibilityIdentifier = "toolRow.videoAttachment.subtitle"
        playButton.accessibilityIdentifier = "toolRow.videoAttachment.play"
        titleLabel.text = title
        titleLabel.textColor = UIColor(palette.fg)
        subtitleLabel.text = lastError ?? subtitle
        subtitleLabel.textColor = lastError == nil ? UIColor(palette.comment) : UIColor(palette.red)
        iconView.tintColor = UIColor(palette.blue)
        spinner.color = UIColor(palette.blue)
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
        playButton.isEnabled = mediaSourceProvider != nil
        updateButton(palette: palette, isLoading: fetchTask != nil)
    }

    static func subtitle(mimeType: String?, sizeBytes: Int?) -> String {
        let type = mimeType?.isEmpty == false ? mimeType ?? "video/unknown" : "video/unknown"
        guard let sizeBytes else { return type }
        return "\(type) • \(ToolCallFormatting.formatBytes(sizeBytes))"
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
        playButton.addTarget(self, action: #selector(playVideo), for: .touchUpInside)
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

    private func updateButton(palette: ThemePalette, isLoading: Bool) {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        playButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        if isLoading {
            playButton.setImage(nil, for: .normal)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        }
        playButton.tintColor = playButton.isEnabled ? UIColor(palette.blue) : UIColor(palette.comment)
    }

    @objc private func playVideo() {
        guard let id, let mediaSourceProvider else { return }

        fetchTask?.cancel()
        lastError = nil
        let playStartedNs = DispatchTime.now().uptimeNanoseconds
        updateButton(palette: ThemeRuntimeState.currentPalette(), isLoading: true)
        fetchTask = Task { [weak self] in
            do {
                let source = try await mediaSourceProvider()
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.fetchTask = nil
                    self.updateButton(palette: ThemeRuntimeState.currentPalette(), isLoading: false)
                    self.presentVideo(source, startedNs: playStartedNs)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.fetchTask = nil
                    self.lastError = error.localizedDescription
                    self.subtitleLabel.text = error.localizedDescription
                    self.subtitleLabel.textColor = UIColor(ThemeRuntimeState.currentPalette().red)
                    self.recordSourceError(error)
                    self.updateButton(palette: ThemeRuntimeState.currentPalette(), isLoading: false)
                }
            }
        }
    }

    private func presentVideo(_ source: AuthenticatedMediaSource, startedNs: UInt64) {
        guard let presenter = ToolTimelineRowPresentationHelpers.nearestViewController(from: self) else { return }
        SystemVideoPlaybackPresenter.present(
            source: source,
            from: presenter,
            telemetrySource: "tool_video_attachment",
            telemetrySessionId: sessionId,
            startedNs: startedNs
        )
    }

    private func recordSourceError(_ error: Error) {
        let kind = MediaPlaybackTelemetry.mediaKind(mimeType: mimeType, sourceFileExtension: sourceFileExtension)
        MediaPlaybackTelemetry.recordError(
            kind: kind,
            source: "tool_video_attachment",
            phase: "source",
            error: error,
            sessionId: sessionId
        )
        MediaPlaybackTelemetry.logError(
            kind: kind,
            source: "tool_video_attachment",
            mode: "fullscreen",
            phase: "source",
            error: error,
            message: "Video source unavailable"
        )
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

@MainActor
private enum ToolImageAttachmentDataCache {
    private static let maxCachedEntryBytes = 8 * 1024 * 1024
    private static let maxCachedBytes = 32 * 1024 * 1024
    private static let maxCachedEntries = 32

    private static var cachedData: [String: Data] = [:]
    private static var cacheOrder: [String] = []
    private static var cachedBytes = 0
    private static var inFlight: [String: Task<Data, Error>] = [:]

    static func key(for attachment: ToolPresentationBuilder.ToolMediaAttachment) -> String {
        [
            attachment.id,
            attachment.mimeType,
            attachment.fileName ?? "",
            attachment.sizeBytes.map(String.init) ?? "",
            attachment.sha256 ?? "",
        ].joined(separator: "|")
    }

    static func data(
        for key: String,
        fetch: @escaping () async throws -> Data
    ) async throws -> Data {
        if let data = cachedData[key] {
            touch(key)
            return data
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task<Data, Error> {
            do {
                let data = try await fetch()
                await store(data, for: key)
                return data
            } catch {
                await removeInFlight(for: key)
                throw error
            }
        }
        inFlight[key] = task
        return try await task.value
    }

    private static func store(_ data: Data, for key: String) {
        inFlight[key] = nil
        guard data.count <= maxCachedEntryBytes else { return }

        if let existing = cachedData[key] {
            cachedBytes -= existing.count
        } else {
            cacheOrder.append(key)
        }
        cachedData[key] = data
        cachedBytes += data.count
        touch(key)
        pruneIfNeeded()
    }

    private static func removeInFlight(for key: String) {
        inFlight[key] = nil
    }

    private static func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private static func pruneIfNeeded() {
        while cachedBytes > maxCachedBytes || cacheOrder.count > maxCachedEntries {
            guard !cacheOrder.isEmpty else { return }
            let key = cacheOrder.removeFirst()
            if let data = cachedData.removeValue(forKey: key) {
                cachedBytes -= data.count
            }
        }
    }
}

final class NativeExpandedInlineImageView: UIView {
    private static let minPreviewHeight = ImageViewportSizing.policy(
        for: .primaryMedia,
        screenHeight: UIScreen.main.bounds.height
    ).placeholderHeight

    private enum AttachmentDataValidationError: Error {
        case sizeMismatch(expected: Int, actual: Int)
        case checksumMismatch(expected: String, actual: String)
    }

    private let imageView = UIImageView()
    private let placeholder = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private let overflowLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint?
    private var naturalHeightToWidthRatio: CGFloat?
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

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePreviewHeightIfNeeded()
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        if let naturalHeightToWidthRatio, targetSize.width > 0 {
            let height = targetPreviewHeight(forWidth: targetSize.width, ratio: naturalHeightToWidthRatio)
            return CGSize(width: targetSize.width, height: height)
        }

        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    private let animatedImageView = AnimatedImageWebContainerView()

    private static func validateAttachmentData(
        _ data: Data,
        attachment: ToolPresentationBuilder.ToolMediaAttachment
    ) throws {
        if let expectedSize = attachment.sizeBytes, expectedSize >= 0, data.count != expectedSize {
            throw AttachmentDataValidationError.sizeMismatch(expected: expectedSize, actual: data.count)
        }

        let expectedHash = attachment.sha256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sha256HexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        if let expectedHash,
           expectedHash.count == 64,
           expectedHash.unicodeScalars.allSatisfy({ sha256HexCharacters.contains($0) }) {
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualHash == expectedHash else {
                throw AttachmentDataValidationError.checksumMismatch(
                    expected: expectedHash,
                    actual: actualHash
                )
            }
        }
    }

    func apply(base64: String, mimeType: String?) {
        let key = ImageDecodeCache.decodeKey(for: base64, maxPixelSize: maxPixelSize)
        guard key != decodedKey else { return }
        decodedKey = key
        prepareForDecode()

        let maxPixelSize = self.maxPixelSize
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                await MainActor.run { [weak self] in
                    guard let self, self.decodedKey == key else { return }
                    self.applyDecodedImage(nil)
                }
                return
            }
            await self?.applyFetchedImageData(data, mimeType: mimeType, key: key, maxPixelSize: maxPixelSize)
        }
    }

    func apply(
        attachment: ToolPresentationBuilder.ToolMediaAttachment,
        fetcher: ((String) async throws -> Data)?
    ) {
        let key = "attachment:\(attachment.id):\(attachment.mimeType):\(attachment.sizeBytes ?? 0):\(attachment.sha256 ?? ""):\(attachment.width ?? 0)x\(attachment.height ?? 0):fetcher=\(fetcher != nil)"
        guard key != decodedKey else { return }
        decodedKey = key

        if let width = attachment.width, let height = attachment.height {
            naturalHeightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(
                width: CGFloat(width),
                height: CGFloat(height)
            )
            updatePreviewHeightIfNeeded()
        } else {
            naturalHeightToWidthRatio = nil
        }
        prepareForDecode()

        guard let fetcher else {
            ClientLog.warning("Network", "Tool image attachment fetcher unavailable", metadata: [
                "attachmentIdPrefix": String(attachment.id.prefix(12)),
                "mimeType": attachment.mimeType,
            ], flush: true)
            applyDecodedImage(nil)
            return
        }

        let maxPixelSize = self.maxPixelSize
        let attachmentCacheKey = ToolImageAttachmentDataCache.key(for: attachment)
        decodeTask = Task { [weak self] in
            let attachmentIdPrefix = String(attachment.id.prefix(12))
            ClientLog.info("Network", "Tool image attachment fetch started", metadata: [
                "attachmentIdPrefix": attachmentIdPrefix,
                "mimeType": attachment.mimeType,
            ])
            do {
                let data = try await ToolImageAttachmentDataCache.data(for: attachmentCacheKey) {
                    let fetchedData = try await fetcher(attachment.id)
                    try Self.validateAttachmentData(fetchedData, attachment: attachment)
                    return fetchedData
                }
                try Self.validateAttachmentData(data, attachment: attachment)
                ClientLog.info("Network", "Tool image attachment fetch completed", metadata: [
                    "attachmentIdPrefix": attachmentIdPrefix,
                    "bytes": String(data.count),
                    "mimeType": attachment.mimeType,
                ])
                await self?.applyFetchedImageData(data, mimeType: attachment.mimeType, key: key, maxPixelSize: maxPixelSize)
            } catch {
                var metadata = ClientLog.networkErrorMetadata(error)
                metadata["attachmentIdPrefix"] = attachmentIdPrefix
                metadata["mimeType"] = attachment.mimeType
                ClientLog.error(
                    "Network",
                    "Tool image attachment fetch failed",
                    metadata: metadata,
                    flush: true
                )
                await MainActor.run { [weak self] in
                    guard let self, self.decodedKey == key else { return }
                    self.decodedKey = nil
                    self.applyDecodedImage(nil)
                }
            }
        }
    }

    func apply(
        filePath: String,
        mimeType: String?,
        fetcher: ((String) async throws -> Data)?
    ) {
        let key = "file:\(filePath):\(mimeType ?? "image/unknown"):fetcher=\(fetcher != nil)"
        guard key != decodedKey else { return }
        decodedKey = key
        naturalHeightToWidthRatio = nil
        prepareForDecode()

        guard let fetcher else {
            applyDecodedImage(nil)
            return
        }

        let maxPixelSize = self.maxPixelSize
        decodeTask = Task { [weak self] in
            do {
                let data = try await fetcher(filePath)
                await self?.applyFetchedImageData(data, mimeType: mimeType, key: key, maxPixelSize: maxPixelSize)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.decodedKey == key else { return }
                    self.applyDecodedImage(nil)
                }
            }
        }
    }

    private func prepareForDecode() {
        decodeTask?.cancel()
        imageView.image = nil
        imageView.isHidden = false
        animatedImageView.isHidden = true
        placeholder.isHidden = false
        placeholder.startAnimating()
        failureLabel.isHidden = true
        overflowLabel.isHidden = true
        accessibilityLabel = "Image preview"
        accessibilityValue = "Loading"
        previewMimeType = nil
        previewData = nil
    }

    private func applyFetchedImageData(
        _ data: Data,
        mimeType: String?,
        key: String,
        maxPixelSize: CGFloat
    ) async {
        let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
        guard MediaMimeType.isCompleteImageData(data, mimeType: info.normalizedMimeType ?? mimeType) else {
            await MainActor.run { [weak self] in
                guard let self, self.decodedKey == key else { return }
                self.decodedKey = nil
                self.applyDecodedImage(nil)
            }
            return
        }
        if info.prefersWebRenderer {
            let normalizedMimeType = MediaMimeType.safeImageMimeType(info.normalizedMimeType, fallback: "image/gif")
            let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
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

        let image = ImageMediaInspector.downsampledImage(data: data, maxPixelSize: maxPixelSize)
        await MainActor.run { [weak self] in
            guard let self, self.decodedKey == key else { return }
            self.applyDecodedImage(image)
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "toolRow.readMedia.imageViewport"
        accessibilityLabel = "Image preview"
        isAccessibilityElement = true
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

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.text = "Image unavailable"
        failureLabel.font = ToolFont.small
        failureLabel.textColor = UIColor(Color.themeComment)
        failureLabel.textAlignment = .center
        failureLabel.isHidden = true
        addSubview(failureLabel)

        overflowLabel.translatesAutoresizingMaskIntoConstraints = false
        overflowLabel.text = "Tap to open full image"
        overflowLabel.font = ToolFont.small
        overflowLabel.textColor = UIColor(Color.themeFg)
        overflowLabel.backgroundColor = UIColor(Color.themeBgDark).withAlphaComponent(0.82)
        overflowLabel.layer.cornerRadius = 6
        overflowLabel.layer.masksToBounds = true
        overflowLabel.textAlignment = .center
        overflowLabel.isHidden = true
        addSubview(overflowLabel)

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
            failureLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            overflowLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            overflowLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            overflowLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        let heightConstraint = heightAnchor.constraint(equalToConstant: Self.minPreviewHeight)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        imageView.addGestureRecognizer(tap)

        let animatedTap = UITapGestureRecognizer(target: self, action: #selector(handleAnimatedImageTap))
        animatedTap.numberOfTapsRequired = 1
        animatedImageView.addGestureRecognizer(animatedTap)
        animatedImageView.isUserInteractionEnabled = true
    }

    private func updatePreviewHeightIfNeeded() {
        guard let naturalHeightToWidthRatio else {
            heightConstraint?.constant = Self.minPreviewHeight
            overflowLabel.isHidden = true
            return
        }

        let availableWidth = bounds.width > 1
            ? bounds.width
            : (superview?.bounds.width ?? UIScreen.main.bounds.width)
        let width = max(1, availableWidth)
        let naturalHeight = ImageViewportSizing.naturalHeight(
            forWidth: width,
            heightToWidthRatio: naturalHeightToWidthRatio
        )
        let targetHeight = targetPreviewHeight(
            forWidth: width,
            ratio: naturalHeightToWidthRatio
        )
        heightConstraint?.constant = targetHeight
        overflowLabel.isHidden = targetHeight >= naturalHeight - 0.5
    }

    private func notifyPreviewSizeChanged() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()

        var ancestor = superview
        var enclosingToolRow: ToolTimelineRowContentView?
        while let current = ancestor {
            current.setNeedsLayout()
            if enclosingToolRow == nil, let row = current as? ToolTimelineRowContentView {
                enclosingToolRow = row
            }
            ancestor = current.superview
        }

        // Pre-layout the enclosing tool row so its viewport-height constraint
        // sees the new inline image height before the collection view asks the
        // cell for a fresh fitting size.
        enclosingToolRow?.layoutIfNeeded()

        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func targetPreviewHeight(forWidth width: CGFloat, ratio: CGFloat) -> CGFloat {
        // Expanded read-media rows should grow to the image's natural
        // aspect-fit height until the primary-media timeline safety limit.
        // The outer timeline owns vertical scrolling; fullscreen remains the
        // unrestricted inspection surface for pathological/tall media.
        ImageViewportSizing.fittedHeight(
            forWidth: width,
            heightToWidthRatio: ratio,
            surface: .primaryMedia,
            screenHeight: window?.bounds.height
        )
    }

    private func applyDecodedImage(_ image: UIImage?) {
        imageView.image = image
        imageView.isHidden = false
        animatedImageView.isHidden = true
        placeholder.stopAnimating()
        placeholder.isHidden = true
        failureLabel.isHidden = image != nil
        accessibilityLabel = image == nil ? "Image unavailable" : "Image preview"
        accessibilityValue = nil

        previewMimeType = nil
        previewData = nil

        guard let image, image.size.width > 0, image.size.height > 0 else {
            naturalHeightToWidthRatio = nil
            heightConstraint?.constant = Self.minPreviewHeight
            notifyPreviewSizeChanged()
            return
        }

        naturalHeightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(
            width: image.size.width,
            height: image.size.height
        )
        updatePreviewHeightIfNeeded()
        notifyPreviewSizeChanged()
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
        failureLabel.isHidden = true
        accessibilityLabel = "Image preview"
        accessibilityValue = nil

        previewData = data
        previewMimeType = mimeType

        if let aspectRatio, aspectRatio > 0 {
            naturalHeightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(1 / aspectRatio)
        } else {
            naturalHeightToWidthRatio = nil
        }
        updatePreviewHeightIfNeeded()
        notifyPreviewSizeChanged()
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        FullScreenImageViewController.present(image: image)
    }

    @objc private func handleAnimatedImageTap() {
        guard let data = previewData,
              let mimeType = previewMimeType,
              let presenter = ToolTimelineRowPresentationHelpers.nearestViewController(from: self) else { return }

        FullScreenImageDataPreviewPresenter.present(data: data, mimeType: mimeType, from: presenter)
    }
}

private struct NativeExpandedReadMediaParsed {
    let strippedText: String
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
}

private enum NativeExpandedReadMediaParser {
    static func containsImageReadBoilerplate(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            isImageReadBoilerplate(line)
        }
    }

    static func containsVideoReadBoilerplate(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            isVideoReadBoilerplate(line)
        }
    }

    static func removingRedundantImageReadBoilerplate(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in !isImageReadBoilerplate(line) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingRedundantVideoReadBoilerplate(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in !isVideoReadBoilerplate(line) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ output: String) -> NativeExpandedReadMediaParsed {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = visibleReadMediaText(from: output)
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = visibleReadMediaText(from: text)
        }

        return NativeExpandedReadMediaParsed(
            strippedText: strippedText,
            images: images,
            audio: audio
        )
    }

    private static func visibleReadMediaText(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !isImageDisplayMetadata($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImageDisplayMetadata(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[Image:")
    }

    private static func isImageReadBoilerplate(_ line: String) -> Bool {
        isMediaReadBoilerplate(line, prefix: "Read image file [", mimePrefix: "image/")
    }

    private static func isVideoReadBoilerplate(_ line: String) -> Bool {
        isMediaReadBoilerplate(line, prefix: "Read video file [", mimePrefix: "video/")
    }

    private static func isMediaReadBoilerplate(_ line: String, prefix: String, mimePrefix: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("]") else { return false }

        let mimeType = trimmed.dropFirst(prefix.count).dropLast()
        return mimeType.lowercased().hasPrefix(mimePrefix)
    }
}
