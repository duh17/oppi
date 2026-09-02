import UIKit

@MainActor
final class NativeAudioMessageView: UIView {
    private let container = UIView()
    private let stack = UIStackView()
    private let strip = NativeAudioPlayerStripView()
    private let messageLabel = UILabel()
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
    private var durationSeconds: TimeInterval?
    private var isUnavailable = false
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? superview?.bounds.width ?? 375
        let targetWidth = max(1, bounds.width > 0 ? bounds.width : fallbackWidth - 48)
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
        suppressAutoplay: Bool = false,
        durationSeconds: TimeInterval? = nil
    ) {
        prepareForApply(
            id: id,
            message: message,
            playbackBehavior: playbackBehavior,
            sessionId: sessionId,
            audioPlayer: audioPlayer,
            palette: palette,
            durationSeconds: durationSeconds
        )
        self.suppressAutoplay = suppressAutoplay
        attachmentId = nil
        attachmentFetcher = nil
        attachmentMediaSourceProvider = nil

        guard MediaMimeType.normalized(mimeType) == "audio/wav" else {
            decodedData = nil
            isUnavailable = true
            refreshStrip()
            return
        }

        isUnavailable = false
        refreshStrip()

        let compactBase64 = base64.filter { !$0.isWhitespace }
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters)
            await MainActor.run { [weak self] in
                guard let self, self.id == id else { return }
                if let data {
                    self.decodedData = data
                    self.isUnavailable = false
                    self.maybeAutoplayDecodedDataIfNeeded()
                } else {
                    self.isUnavailable = true
                }
                self.refreshStrip()
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
        suppressAutoplay: Bool = false,
        durationSeconds: TimeInterval? = nil
    ) {
        prepareForApply(
            id: id,
            message: message,
            playbackBehavior: playbackBehavior,
            sessionId: sessionId,
            audioPlayer: audioPlayer,
            palette: palette,
            durationSeconds: durationSeconds
        )
        self.suppressAutoplay = suppressAutoplay
        self.attachmentId = attachmentId
        self.attachmentFetcher = attachmentFetcher
        self.attachmentMediaSourceProvider = attachmentMediaSourceProvider

        if attachmentId.isEmpty {
            // Live stream / speaking card: empty attachment is loading/playing, not failure.
            isUnavailable = false
            refreshStrip()
            return
        }

        guard MediaMimeType.normalized(mimeType) == "audio/wav", attachmentMediaSourceProvider != nil else {
            self.attachmentFetcher = nil
            self.attachmentMediaSourceProvider = nil
            isUnavailable = true
            refreshStrip()
            return
        }

        isUnavailable = false
        refreshStrip()
        maybeAutoplayAttachmentIfNeeded()
    }

    private func prepareForApply(
        id: String,
        message: String,
        playbackBehavior: AudioPlaybackBehavior?,
        sessionId: String?,
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette,
        durationSeconds: TimeInterval?
    ) {
        self.id = id
        self.audioPlayer = audioPlayer
        self.playbackBehavior = playbackBehavior
        self.sessionId = sessionId
        self.durationSeconds = durationSeconds
        accessibilityIdentifier = "chat.timeline.row.\(id).audio.message"
        messageLabel.accessibilityIdentifier = "chat.timeline.row.\(id).audio.message.transcript"
        self.decodedData = nil
        self.attachmentId = nil
        self.attachmentFetcher = nil
        self.attachmentMediaSourceProvider = nil
        fetchTask?.cancel()
        fetchTask = nil
        bindAudioStateObservationIfNeeded()

        container.backgroundColor = .clear
        container.layer.borderColor = UIColor.clear.cgColor
        messageLabel.textColor = UIColor(palette.fg)
        spinner.color = UIColor(palette.purple)
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
        refreshStrip()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10

        messageLabel.font = AppFont.messageBody
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        addSubview(container)
        container.addSubview(stack)
        container.addSubview(spinner)
        stack.addArrangedSubview(strip)
        stack.addArrangedSubview(messageLabel)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id = self.id, self.audioPlayer?.loadingItemID == id {
                    self.spinner.startAnimating()
                } else {
                    self.spinner.stopAnimating()
                }
            }
        }
    }

    private func refreshStrip() {
        guard let id else { return }
        strip.apply(
            itemID: id,
            title: nil,
            durationSeconds: durationSeconds,
            audioPlayer: audioPlayer,
            showsTitle: false,
            isUnavailable: isUnavailable,
            onPlay: { [weak self] in self?.togglePlayback() },
            onExpand: { [weak self] in self?.expand() }
        )
    }

    private func togglePlayback() {
        guard let id, let audioPlayer else { return }
        if audioPlayer.playingItemID == id {
            if audioPlayer.isPaused {
                audioPlayer.resume()
            } else {
                audioPlayer.pause()
            }
            return
        }
        if let decodedData {
            audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
            return
        }
        guard let attachmentId, let attachmentMediaSourceProvider else { return }
        spinner.startAnimating()
        fetchTask?.cancel()
        fetchTask = Task { [weak self, attachmentId, id, weak audioPlayer] in
            do {
                let source = try await attachmentMediaSourceProvider(attachmentId, "audio/wav", "wav")
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    audioPlayer?.toggleMediaPlayback(source: source, itemID: id)
                    self.refreshStrip()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.isUnavailable = true
                    self.spinner.stopAnimating()
                    self.refreshStrip()
                }
            }
        }
    }

    private func expand() {
        guard let id else { return }
        AudioLyricsPlayerPresenter.present(
            from: self,
            title: String(localized: "Voice message"),
            lyrics: messageLabel.attributedText?.string,
            itemID: id,
            audioPlayer: audioPlayer,
            play: { [weak self] in
                guard let self else { return }
                if self.audioPlayer?.playingItemID != id {
                    self.togglePlayback()
                } else if self.audioPlayer?.isPaused == true {
                    self.audioPlayer?.resume()
                }
            },
            openFile: isUnavailable ? { [weak self] in self?.togglePlayback() } : nil,
            autoplayOnAppear: AudioLyricsPlayerPresenter.shouldAutoplayOnAppear(
                itemID: id,
                audioPlayer: audioPlayer,
                playNow: playbackBehavior == .playNow
            )
        )
    }

    private func maybeAutoplayDecodedDataIfNeeded() {
        guard !suppressAutoplay,
              let id, let decodedData, let audioPlayer,
              audioPlayer.shouldAutoplayAudioMessage(itemID: id, playbackBehavior: playbackBehavior, sessionId: sessionId) else {
            return
        }
        audioPlayer.markVoiceReplyAutoplayed(itemID: id)
        audioPlayer.toggleDataPlayback(data: decodedData, itemID: id, mode: "autoplay")
        refreshStrip()
    }

    private func maybeAutoplayAttachmentIfNeeded() {
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
                    self.refreshStrip()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.isUnavailable = true
                    self.spinner.stopAnimating()
                    self.refreshStrip()
                }
            }
        }
    }

    private func fittedSize(forWidth width: CGFloat) -> CGSize {
        let innerWidth = max(1, width)
        let stripHeight = MarkdownInlineAudioLayout.compactHeight
        let messageHeight: CGFloat
        if messageLabel.isHidden {
            messageHeight = 0
        } else {
            messageHeight = ceil(
                messageLabel.sizeThatFits(
                    CGSize(width: innerWidth, height: .greatestFiniteMagnitude)
                ).height
            )
        }
        let spacing: CGFloat = messageLabel.isHidden ? 0 : stack.spacing
        let totalHeight = stripHeight + spacing + messageHeight
        return CGSize(width: width, height: ceil(totalHeight))
    }
}
