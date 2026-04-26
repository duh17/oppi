import UIKit

@MainActor
final class NativeVoiceMessageView: UIView {
    private static let maxDecodedBytes = 10 * 1024 * 1024

    private let container = UIView()
    private let stack = UIStackView()
    private let headerRow = UIStackView()
    private let headerIconView = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let headerLabel = UILabel()
    private let messageLabel = UILabel()
    private let controlsRow = UIStackView()
    private let transcriptStack = UIStackView()
    private let playButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var id: String?
    private var audioPlayer: AudioPlayerService?
    private var decodedData: Data?
    private var attachmentId: String?
    private var attachmentFetcher: ((String) async throws -> Data)?
    private var decodeTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette
    ) {
        prepareForApply(id: id, message: message, audioPlayer: audioPlayer, palette: palette)
        attachmentId = nil
        attachmentFetcher = nil

        guard mimeType?.lowercased() == "audio/wav" else {
            playButton.isEnabled = false
            progressView.isHidden = true
            updateButton(palette: palette)
            return
        }

        let compactBase64 = base64.filter { !$0.isWhitespace }
        guard estimatedDecodedByteCount(compactBase64) <= Self.maxDecodedBytes else {
            playButton.isEnabled = false
            progressView.isHidden = true
            updateButton(palette: palette)
            return
        }

        playButton.isEnabled = false
        progressView.progress = 0
        progressView.isHidden = false
        updateButton(palette: palette)

        decodeTask?.cancel()
        let maxDecodedBytes = Self.maxDecodedBytes
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters)
            await MainActor.run { [weak self] in
                guard let self, self.id == id else { return }
                if let data, data.count <= maxDecodedBytes {
                    self.decodedData = data
                    self.playButton.isEnabled = audioPlayer != nil
                    self.progressView.progress = 0
                } else {
                    self.playButton.isEnabled = false
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
        audioPlayer: AudioPlayerService?,
        attachmentFetcher: ((String) async throws -> Data)?,
        palette: ThemePalette
    ) {
        prepareForApply(id: id, message: message, audioPlayer: audioPlayer, palette: palette)
        self.attachmentId = attachmentId
        self.attachmentFetcher = attachmentFetcher

        guard mimeType?.lowercased() == "audio/wav", attachmentFetcher != nil else {
            playButton.isEnabled = false
            progressView.isHidden = true
            updateButton(palette: palette)
            return
        }

        playButton.isEnabled = audioPlayer != nil
        progressView.progress = 0
        progressView.isHidden = true
        updateButton(palette: palette)
    }

    private func prepareForApply(
        id: String,
        message: String,
        audioPlayer: AudioPlayerService?,
        palette: ThemePalette
    ) {
        self.id = id
        self.audioPlayer = audioPlayer
        self.decodedData = nil
        self.attachmentId = nil
        self.attachmentFetcher = nil
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
        playButton.tintColor = UIColor(palette.purple)
        headerLabel.text = "Voice message"
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
                    .font: ToolFont.regular,
                ]
            )
        messageLabel.isHidden = trimmedMessage.isEmpty
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

        messageLabel.font = ToolFont.regular
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        controlsRow.axis = .horizontal
        controlsRow.alignment = .top
        controlsRow.spacing = 12

        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.axis = .vertical
        transcriptStack.alignment = .fill
        transcriptStack.spacing = 10
        transcriptStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transcriptStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        progressView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        container.addSubview(stack)
        playButton.addSubview(spinner)
        headerRow.addArrangedSubview(headerIconView)
        headerRow.addArrangedSubview(headerLabel)
        transcriptStack.addArrangedSubview(progressView)
        transcriptStack.addArrangedSubview(messageLabel)
        controlsRow.addArrangedSubview(playButton)
        controlsRow.addArrangedSubview(transcriptStack)
        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(controlsRow)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            transcriptStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            headerIconView.widthAnchor.constraint(equalToConstant: 16),
            headerIconView.heightAnchor.constraint(equalToConstant: 16),
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
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
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
        guard let id, let audioPlayer else { return }
        if let decodedData {
            audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
            updateButton(palette: ThemeRuntimeState.currentPalette())
            return
        }

        guard let attachmentId, let attachmentFetcher else { return }
        playButton.isEnabled = false
        spinner.startAnimating()
        fetchTask?.cancel()
        fetchTask = Task { [weak self, attachmentId, id, weak audioPlayer] in
            do {
                let data = try await attachmentFetcher(attachmentId)
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.decodedData = data
                    self.playButton.isEnabled = true
                    audioPlayer?.toggleDataPlayback(data: data, itemID: id)
                    self.updateButton(palette: ThemeRuntimeState.currentPalette())
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.id == id else { return }
                    self.playButton.isEnabled = self.audioPlayer != nil
                    self.spinner.stopAnimating()
                    self.updateButton(palette: ThemeRuntimeState.currentPalette())
                }
            }
        }
    }

    private func fittedSize(forWidth width: CGFloat) -> CGSize {
        let outerInsets: CGFloat = 24
        let innerWidth = max(1, width - outerInsets)
        let transcriptWidth = max(1, innerWidth - 44 - 12)

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
        let controlsHeight = max(44, transcriptHeight)
        let totalHeight = outerInsets + controlsHeight
        return CGSize(width: width, height: ceil(totalHeight))
    }

    private func estimatedDecodedByteCount(_ base64: String) -> Int {
        max(0, (base64.count * 3) / 4 - base64.suffix(2).filter { $0 == "=" }.count)
    }
}
