import UIKit

@MainActor
final class NativeAudioMessageView: UIView {
    private let container = UIView()
    private let stack = UIStackView()
    private let headerRow = UIStackView()
    private let headerIconView = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let headerLabel = UILabel()
    private let messageLabel = UILabel()
    private let transcriptStack = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var id: String?
    private var audioPlayer: AudioPlayerService?
    private var decodedData: Data?
    private var attachmentId: String?
    private var attachmentFetcher: ((String) async throws -> Data)?
    private var attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)?
    private var playbackBehavior: AudioPlaybackBehavior?
    private var sessionId: String?
    private var decodeTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var suppressAutoplay = false
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let targetWidth = max(1, bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 48)
        return CGSize(width: UIView.noIntrinsicMetric, height: fittedSize(forWidth: targetWidth).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let targetWidth = max(1, size.width > 0 ? size.width : bounds.width)
        return fittedSize(forWidth: targetWidth)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let targetWidth = max(1, targetSize.width > 0 ? targetSize.width : bounds.width)
        return fittedSize(forWidth: targetWidth)
    }

    deinit {
        decodeTask?.cancel()
        fetchTask?.cancel()
        if let audioStateObserver {
            NotificationCenter.default.removeObserver(audioStateObserver)
        }
    }

    func apply(
        id: String,
        message: String,
        base64: String,
        mimeType: String?,
        playbackBehavior: AudioPlaybackBehavior?,
        sessionId: String?,
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette,
        suppressAutoplay: Bool = false
    ) {
        prepareForApply(id: id, message: message, playbackBehavior: playbackBehavior, sessionId: sessionId, audioPlayer: audioPlayer, palette: palette)
        self.suppressAutoplay = suppressAutoplay
        attachmentId = nil
        attachmentFetcher = nil
        attachmentMediaSourceProvider = nil

        guard MediaMimeType.normalized(mimeType) == "audio/wav" else {
            decodedData = nil
            progressView.isHidden = true
            updateButton(palette: palette)
            return
        }

        let compactBase64 = base64.filter { !$0.isWhitespace }

        progressView.progress = 0
        progressView.isHidden = false
        updateButton(palette: palette)

        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters)
            await MainActor.run { [weak self] in
                guard let self, self.id == id else { return }
                if let data {
                    self.decodedData = data
                    self.progressView.progress = 0
                    self.maybeAutoplayDecodedDataIfNeeded(palette: palette)
                } else {
                    self.progressView.isHidden = true
                }
                self.updateButton(palette: palette)
                ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            }
        }
    }

    func apply(
        id: String,
        message: String,
        attachmentId: String,
        mimeType: String?,
        playbackBehavior: AudioPlaybackBehavior?,
        sessionId: String?,
        audioPlayer: AudioPlayerService?,
        attachmentFetcher: ((String) async throws -> Data)?,
        attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)? = nil,
        palette: ThemePalette,
        suppressAutoplay: Bool = false
    ) {
        prepareForApply(id: id, message: message, playbackBehavior: playbackBehavior, sessionId: sessionId, audioPlayer: audioPlayer, palette: palette)
        self.suppressAutoplay = suppressAutoplay
        self.attachmentId = attachmentId
        self.attachmentFetcher = attachmentFetcher
        self.attachmentMediaSourceProvider = attachmentMediaSourceProvider

        guard MediaMimeType.normalized(mimeType) == "audio/wav", attachmentMediaSourceProvider != nil else {
            self.attachmentFetcher = nil
            self.attachmentMediaSourceProvider = nil
            progressView.isHidden = true
            updateButton(palette: palette)
            return
        }

        progressView.progress = 0
        progressView.isHidden = true
        updateButton(palette: palette)
        maybeAutoplayAttachmentIfNeeded(palette: palette)
    }

    private func prepareForApply(
        id: String,
        message: String,
        playbackBehavior: AudioPlaybackBehavior?,
        sessionId: String?,
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette
    ) {
        self.id = id
        self.audioPlayer = audioPlayer
        self.playbackBehavior = playbackBehavior
        self.sessionId = sessionId
        self.decodedData = nil
        self.attachmentId = nil
        self.attachmentFetcher = nil
        self.attachmentMediaSourceProvider = nil
        fetchTask?.cancel()
        fetchTask = nil
        bindAudioStateObservationIfNeeded()

        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
        headerIconView.tintColor = UIColor(palette.purple)
        headerLabel.textColor = UIColor(palette.purple)
        messageLabel.textColor = UIColor(palette.fg)
        spinner.color = UIColor(palette.purple)
        progressView.progressTintColor = UIColor(palette.purple)
        progressView.trackTintColor = UIColor(palette.comment).withAlphaComponent(0.2)
        headerLabel.text = nil
        headerRow.isHidden = true
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 3
        messageLabel.attributedText = trimmedMessage.isEmpty
            ? nil
            : NSAttributedString(
                string: trimmedMessage,
                attributes: [
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: UIColor(palette.fg),
                    .font: AppFont.messageBody,
                ]
            )
        messageLabel.isHidden = trimmedMessage.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 12
        container.layer.borderWidth = 1

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10

        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8

        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerIconView.contentMode = .scaleAspectFit
        headerIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        headerLabel.font = ToolFont.smallBold
        headerLabel.numberOfLines = 1
        headerLabel.lineBreakMode = .byTruncatingTail

        messageLabel.font = AppFont.messageBody
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.axis = .vertical
        transcriptStack.alignment = .fill
        transcriptStack.spacing = 10
        transcriptStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transcriptStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        progressView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        container.addSubview(stack)
        container.addSubview(spinner)
        headerRow.addArrangedSubview(headerIconView)
        headerRow.addArrangedSubview(headerLabel)
        transcriptStack.addArrangedSubview(progressView)
        transcriptStack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(transcriptStack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            transcriptStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            headerIconView.widthAnchor.constraint(equalToConstant: 16),
            headerIconView.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
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

    private func updateButton(palette _: ThemePalette) {
        guard let id else { return }
        if audioPlayer?.loadingItemID == id {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    private func maybeAutoplayDecodedDataIfNeeded(palette: ThemePalette) {
        guard !suppressAutoplay,
              let id, let decodedData, let audioPlayer,
              audioPlayer.shouldAutoplayAudioMessage(itemID: id, playbackBehavior: playbackBehavior, sessionId: sessionId) else {
            return
        }
        audioPlayer.markVoiceReplyAutoplayed(itemID: id)
        audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
        updateButton(palette: palette)
    }

    private func maybeAutoplayAttachmentIfNeeded(palette: ThemePalette) {
        guard !suppressAutoplay,
              let id, let attachmentId, let audioPlayer, let attachmentMediaSourceProvider,
              audioPlayer.shouldAutoplayAudioMessage(itemID: id, playbackBehavior: playbackBehavior, sessionId: sessionId) else {
            return
        }
        spinner.startAnimating()
        fetchTask?.cancel()
        fetchTask = Task { [weak self, attachmentId, id, weak audioPlayer] in
            do {
                let source = try await attachmentMediaSourceProvider(attachmentId, "audio/wav", "wav")
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    audioPlayer?.markVoiceReplyAutoplayed(itemID: id)
                    audioPlayer?.toggleMediaPlayback(source: source, itemID: id, mode: "autoplay")
                    self.updateButton(palette: ThemeRuntimeState.currentPalette())
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.spinner.stopAnimating()
                    self.updateButton(palette: ThemeRuntimeState.currentPalette())
                }
            }
        }
    }

    private func fittedSize(forWidth width: CGFloat) -> CGSize {
        let outerInsets: CGFloat = 24
        let innerWidth = max(1, width - outerInsets)
        let transcriptWidth = max(1, innerWidth)

        let progressHeight: CGFloat = progressView.isHidden ? 0 : 2
        let messageHeight: CGFloat
        if messageLabel.isHidden {
            messageHeight = 0
        } else {
            messageHeight = ceil(
                messageLabel.sizeThatFits(
                    CGSize(width: transcriptWidth, height: .greatestFiniteMagnitude)
                ).height
            )
        }

        let transcriptSpacing: CGFloat = (!progressView.isHidden && !messageLabel.isHidden) ? transcriptStack.spacing : 0
        let transcriptHeight = progressHeight + transcriptSpacing + messageHeight
        let totalHeight = outerInsets + transcriptHeight
        return CGSize(width: width, height: ceil(totalHeight))
    }
}
