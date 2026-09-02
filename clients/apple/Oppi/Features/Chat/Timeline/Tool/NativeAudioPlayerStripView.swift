import UIKit

/// Compact play/progress/expand strip shared by voice cards and markdown audio embeds.
@MainActor
final class NativeAudioPlayerStripView: UIView {
    private let playButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let expandButton = UIButton(type: .system)
    private let unavailableLabel = UILabel()

    private var itemID: String?
    private var audioPlayer: AudioPlayerService?
    private var durationSeconds: TimeInterval?
    private var onPlay: (() -> Void)?
    private var onExpand: (() -> Void)?
    private var showsTitle = true
    nonisolated(unsafe) private var audioStateObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        bindAudioStateObservationIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let audioStateObserver {
            NotificationCenter.default.removeObserver(audioStateObserver)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: MarkdownInlineAudioLayout.compactHeight)
    }

    func apply(
        itemID: String,
        title: String?,
        durationSeconds: TimeInterval?,
        audioPlayer: AudioPlayerService?,
        showsTitle: Bool,
        isUnavailable: Bool,
        onPlay: @escaping () -> Void,
        onExpand: @escaping () -> Void
    ) {
        self.itemID = itemID
        self.audioPlayer = audioPlayer
        self.durationSeconds = durationSeconds
        self.showsTitle = showsTitle
        self.onPlay = onPlay
        self.onExpand = onExpand
        accessibilityIdentifier = "chat.timeline.row.\(itemID).audio.strip"
        playButton.accessibilityIdentifier = "chat.timeline.row.\(itemID).audio.play"
        expandButton.accessibilityIdentifier = "chat.timeline.row.\(itemID).audio.expand"
        timeLabel.accessibilityIdentifier = "chat.timeline.row.\(itemID).audio.time"

        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgDark)
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
        playButton.tintColor = UIColor(palette.purple)
        expandButton.tintColor = UIColor(palette.comment)
        titleLabel.textColor = UIColor(palette.fg)
        timeLabel.textColor = UIColor(palette.comment)
        progressView.progressTintColor = UIColor(palette.purple)
        progressView.trackTintColor = UIColor(palette.comment).withAlphaComponent(0.25)
        unavailableLabel.textColor = UIColor(palette.comment)

        titleLabel.text = title
        titleLabel.isHidden = !showsTitle || (title?.isEmpty ?? true) || isUnavailable
        unavailableLabel.isHidden = !isUnavailable
        playButton.isHidden = isUnavailable
        progressView.isHidden = isUnavailable
        timeLabel.isHidden = isUnavailable
        expandButton.isHidden = false
        expandButton.accessibilityLabel = isUnavailable ? "Open audio file" : "Expand player"
        playButton.accessibilityLabel = playAccessibilityLabel()
        refreshPlaybackChrome()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 12
        layer.borderWidth = 1

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 1

        timeLabel.font = .preferredFont(forTextStyle: .caption1)
        timeLabel.adjustsFontForContentSizeCategory = true

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progress = 0

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.setImage(
            UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
            for: .normal
        )
        expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
        expandButton.accessibilityLabel = "Expand player"

        unavailableLabel.font = .preferredFont(forTextStyle: .subheadline)
        unavailableLabel.adjustsFontForContentSizeCategory = true
        unavailableLabel.text = String(localized: "Audio unavailable")
        unavailableLabel.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, timeLabel, progressView])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 4
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let playHit = UIView()
        playHit.translatesAutoresizingMaskIntoConstraints = false
        playHit.addSubview(playButton)
        let expandHit = UIView()
        expandHit.translatesAutoresizingMaskIntoConstraints = false
        expandHit.addSubview(expandButton)

        let row = UIStackView(arrangedSubviews: [playHit, textStack, expandHit])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        addSubview(unavailableLabel)

        NSLayoutConstraint.activate([
            playHit.widthAnchor.constraint(equalToConstant: 44),
            playHit.heightAnchor.constraint(equalToConstant: 44),
            expandHit.widthAnchor.constraint(equalToConstant: 44),
            expandHit.heightAnchor.constraint(equalToConstant: 44),
            playButton.leadingAnchor.constraint(equalTo: playHit.leadingAnchor),
            playButton.trailingAnchor.constraint(equalTo: playHit.trailingAnchor),
            playButton.topAnchor.constraint(equalTo: playHit.topAnchor),
            playButton.bottomAnchor.constraint(equalTo: playHit.bottomAnchor),
            expandButton.leadingAnchor.constraint(equalTo: expandHit.leadingAnchor),
            expandButton.trailingAnchor.constraint(equalTo: expandHit.trailingAnchor),
            expandButton.topAnchor.constraint(equalTo: expandHit.topAnchor),
            expandButton.bottomAnchor.constraint(equalTo: expandHit.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 3),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            unavailableLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            unavailableLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -54),
            unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: MarkdownInlineAudioLayout.compactHeight),
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
                self?.refreshPlaybackChrome()
            }
        }
    }

    private func refreshPlaybackChrome() {
        let imageName = isActivePlaying() ? "pause.fill" : "play.fill"
        playButton.setImage(
            UIImage(systemName: imageName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
            for: .normal
        )
        playButton.accessibilityLabel = playAccessibilityLabel()

        let elapsed: TimeInterval
        let duration: TimeInterval?
        if isMatchingPlayback() {
            elapsed = audioPlayer?.currentTime ?? 0
            duration = audioPlayer?.duration ?? durationSeconds
        } else {
            elapsed = 0
            duration = durationSeconds
        }
        timeLabel.text = AudioPlaybackTimeFormatting.elapsedDuration(elapsed: elapsed, duration: duration)
        if let duration, duration > 0 {
            progressView.progress = Float(min(max(elapsed / duration, 0), 1))
        } else {
            progressView.progress = 0
        }
    }

    private func isMatchingPlayback() -> Bool {
        guard let itemID, let audioPlayer else { return false }
        return audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID)
    }

    private func isActivePlaying() -> Bool {
        isMatchingPlayback() && audioPlayer?.isPaused == false
    }

    private func playAccessibilityLabel() -> String {
        isActivePlaying() ? "Pause audio" : "Play audio"
    }

    @objc private func handlePlay() {
        onPlay?()
        refreshPlaybackChrome()
    }

    @objc private func handleExpand() {
        onExpand?()
    }
}
