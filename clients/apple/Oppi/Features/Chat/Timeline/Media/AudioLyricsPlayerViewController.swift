import SwiftUI
import UIKit

/// Full-screen audio player: header, lyrics or script transcript, and transport.
///
/// Presented directly for modal playback and hosted by ``AudioLyricsPlayerView``
/// in SwiftUI navigation. Reads `AudioPlayerService` inside `updateProperties()`,
/// so UIKit observation tracking follows playback without a SwiftUI body.
final class AudioLyricsPlayerViewController: UIViewController {
    struct Configuration {
        var title: String
        var lyrics: String?
        var itemID: String
        var audioPlayer: AudioPlayerService?
        var play: (TimedText.LoadResult?) -> Void
        var openFile: (() -> Void)?
        var shareFileData: (() async throws -> Data)?
        var autoplayOnAppear = false
        var showsCloseButton = true
        var usesNavigationBackButton = false
        var titlePresentation: AudioLyricsPlayerTitlePresentation = .playerShowsTitle
        var timedText: TimedText.LoadResult?
        var sidecarLoader: (() async -> TimedText.LoadResult)?
        /// Leaves the host surface. `nil` dismisses this controller's own presentation.
        var dismiss: (() -> Void)?
    }

    private var configuration: Configuration
    private var style = AudioPlayerChromeStyle()

    private var selectedTrackIndex: Int?
    private var loadedTimedText: TimedText.LoadResult?
    /// Auto-scroll follows the current line until the reader drags the text.
    private var followsPlayback = true
    private var didAutoplay = false
    private var sidecarTask: Task<Void, Never>?
    private var backSwipe: HorizontalBackSwipeGestureInstaller?

    /// Content derived from the timed text; rebuilt only when the text or track changes.
    private var lines: [AudioLyrics.Line] = []
    private var transcriptStyle: AudioTranscriptStyle = .lyrics
    private var transcriptPalette: AudioTranscriptPalette?
    private var renderedCurrentIndex: Int??
    private var showsFollowButton = false

    private let headerStack = UIStackView()
    private lazy var backButton = makeAudioIconButton(
        symbol: "chevron.backward",
        pointSize: 17,
        tint: style.cyan,
        label: String(localized: "Back"),
        identifier: "fullscreen-audio.back"
    )
    private let doneButton = UIButton(configuration: .plain())
    private let titleLabel = UILabel()
    private lazy var stopButton = makeAudioIconButton(
        symbol: "xmark",
        pointSize: 17,
        tint: style.foreground,
        label: String(localized: "Stop Playback"),
        identifier: "audioLyrics.stop"
    )
    private let languageButton = UIButton(configuration: .plain())
    private lazy var shareButton = AudioFileShareButton(style: style)

    private let emptyLabel = UILabel()
    private lazy var castStrip = AudioCastStripView(style: style)
    private let transcript = AudioTranscriptCollectionView()
    private let transcriptFade = AudioTranscriptFadeView()
    private let followButton = UIButton(configuration: .plain())
    private lazy var transport = AudioPlaybackTransportView(density: .fullScreen)

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        sidecarTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: .oppiThemeDidChange, object: nil)
    }

    /// Timed text the play action should start with: the reader's chosen track wins.
    static func selectedTimedTextForPlayback(
        _ timedText: TimedText.LoadResult?,
        selectedTrackIndex: Int?
    ) -> TimedText.LoadResult? {
        guard var selected = timedText else { return nil }
        if let selectedTrackIndex,
           selected.tracks.indices.contains(selectedTrackIndex) {
            selected.selectedIndex = selectedTrackIndex
        }
        return selected
    }

    func apply(_ newConfiguration: Configuration) {
        let contentChanged = newConfiguration.lyrics != configuration.lyrics
            || newConfiguration.timedText != configuration.timedText
        configuration = newConfiguration
        guard isViewLoaded else { return }
        applyChrome()
        applyTransport()
        if contentChanged { rebuildContent() }
        setNeedsUpdateProperties()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        let body = buildBody()
        for subview in [headerStack, body, transport] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            guide.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor, constant: 16),
            body.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            transport.topAnchor.constraint(equalTo: body.bottomAnchor),
            transport.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        applyChrome()
        applyTransport()
        applyStyle()
        loadSidecar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
        // Button configuration titles do not follow Dynamic Type on their own.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: Self, _) in
            controller.applyStyle()
        }
    }

    @objc private func themeDidChange() {
        style = AudioPlayerChromeStyle()
        applyStyle()
    }

    /// Colors and button configurations from the current theme and text size.
    /// Rebuilding content repaints the cast, transcript palette, and language label.
    private func applyStyle() {
        view.backgroundColor = style.background
        backButton.configuration?.baseForegroundColor = style.cyan
        stopButton.configuration?.baseForegroundColor = style.foreground
        doneButton.configuration = style.capsuleConfiguration(
            title: String(localized: "Done"),
            font: AudioPlayerChromeStyle.font(.body, weight: .semibold),
            foreground: style.cyan,
            insets: NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        )
        titleLabel.textColor = style.foreground
        shareButton.apply(style)
        emptyLabel.textColor = style.comment
        followButton.configuration = style.capsuleConfiguration(
            title: String(localized: "Current Line"),
            symbol: "text.line.first.and.arrowtriangle.forward",
            font: AudioPlayerChromeStyle.font(.subheadline, weight: .semibold),
            foreground: style.foreground,
            fillAlpha: 0.95,
            insets: NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        )
        castStrip.style = style
        rebuildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard configuration.autoplayOnAppear, !didAutoplay else { return }
        didAutoplay = true
        configuration.play(playbackTimedText)
    }

    override func updateProperties() {
        super.updateProperties()
        let player = configuration.audioPlayer
        let matches = player.map {
            $0.playingItemID == configuration.itemID || $0.isStreamingPlaybackActive(itemID: configuration.itemID)
        } ?? false
        let currentIndex = AudioLyrics.presentationCurrentIndex(in: lines, at: matches ? player?.currentTime : nil)
        guard renderedCurrentIndex != .some(currentIndex) else { return }
        renderedCurrentIndex = currentIndex
        renderPlayback(currentIndex: currentIndex)
    }

    // MARK: - Content

    private var resolvedTimedText: TimedText.LoadResult? {
        loadedTimedText ?? configuration.timedText
    }

    private var resolvedTrackIndex: Int {
        selectedTrackIndex ?? resolvedTimedText?.selectedIndex ?? 0
    }

    private var selectedTrack: TimedText.Track? {
        guard let resolvedTimedText, resolvedTimedText.tracks.indices.contains(resolvedTrackIndex) else { return nil }
        return resolvedTimedText.tracks[resolvedTrackIndex]
    }

    private var playbackTimedText: TimedText.LoadResult? {
        Self.selectedTimedTextForPlayback(resolvedTimedText, selectedTrackIndex: selectedTrackIndex)
    }

    private func loadSidecar() {
        guard let sidecarLoader = configuration.sidecarLoader else { return }
        sidecarTask = Task { [weak self] in
            let loaded = await sidecarLoader()
            guard !Task.isCancelled, let self else { return }
            loadedTimedText = loaded
            rebuildContent()
        }
    }

    private func rebuildContent() {
        lines = selectedTrack.map { TimedText.lyricsLines(from: $0.cues) } ?? AudioLyrics.lines(from: configuration.lyrics)
        applyLanguageControl()

        let isEmpty = lines.isEmpty
        let isScript = AudioReaderCast.isScript(lines)
        emptyLabel.isHidden = !isEmpty
        transcriptFade.isHidden = isEmpty
        castStrip.isHidden = isEmpty || !isScript

        var speakerColors: [String: UIColor] = [:]
        if isScript {
            let cast = AudioReaderCast.members(in: lines, voiceColors: selectedTrack?.voiceColors ?? [:])
            speakerColors = Dictionary(uniqueKeysWithValues: cast.map { ($0.name, color(for: $0)) })
            castStrip.setCast(cast.map { ($0.name, speakerColors[$0.name] ?? style.comment) })
        }
        transcriptStyle = isScript ? .script : .lyrics
        transcriptPalette = AudioTranscriptPalette(
            foreground: style.foreground,
            dimmed: style.comment,
            unnamed: style.comment,
            speakerColors: speakerColors
        )
        renderedCurrentIndex = nil
        setNeedsUpdateProperties()
    }

    /// Authored WebVTT colors win; other speakers take theme accents so they follow the theme.
    private func color(for member: AudioReaderCast.Member) -> UIColor {
        if let hex = member.colorHex, let authored = Color(hex: hex) {
            return UIColor(authored)
        }
        return style.speakerAccents[member.paletteIndex % style.speakerAccents.count]
    }

    private func renderPlayback(currentIndex: Int?) {
        if !lines.isEmpty, let transcriptPalette {
            transcript.update(
                lines: lines,
                style: transcriptStyle,
                palette: transcriptPalette,
                currentIndex: currentIndex,
                followsPlayback: followsPlayback
            )
        }
        if transcriptStyle == .script {
            castStrip.setSpeaking(currentIndex.flatMap { lines.indices.contains($0) ? lines[$0].speaker : nil })
        }
        let showsFollow = !followsPlayback && currentIndex != nil
        guard showsFollow != showsFollowButton else { return }
        showsFollowButton = showsFollow
        if showsFollow { followButton.isHidden = false }
        UIView.animate(withDuration: 0.2) {
            self.followButton.alpha = showsFollow ? 1 : 0
        } completion: { _ in
            if !self.showsFollowButton { self.followButton.isHidden = true }
        }
    }

    private func setFollowsPlayback(_ follows: Bool) {
        guard follows != followsPlayback else { return }
        followsPlayback = follows
        renderedCurrentIndex = nil
        setNeedsUpdateProperties()
    }

    private func jump(toLine index: Int) {
        guard lines.indices.contains(index), let start = lines[index].startTime else { return }
        setFollowsPlayback(true)
        configuration.audioPlayer?.seek(to: start)
    }

    private func selectTrack(_ index: Int) {
        guard var selected = resolvedTimedText, selected.tracks.indices.contains(index) else { return }
        selectedTrackIndex = index
        selected.selectedIndex = index
        configuration.audioPlayer?.setNowPlayingTimedText(selected, for: configuration.itemID)
        rebuildContent()
    }

    // MARK: - Header

    private func buildHeader() {
        doneButton.addAction(UIAction { [weak self] _ in self?.leave() }, for: .primaryActionTriggered)
        backButton.addAction(UIAction { [weak self] _ in self?.leave() }, for: .primaryActionTriggered)
        stopButton.addAction(UIAction { [weak self] _ in
            self?.configuration.audioPlayer?.stop()
        }, for: .primaryActionTriggered)

        titleLabel.font = AudioPlayerChromeStyle.font(.subheadline, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        languageButton.showsMenuAsPrimaryAction = true
        languageButton.accessibilityLabel = String(localized: "Lyrics language")
        languageButton.accessibilityIdentifier = "audioLyrics.language"
        languageButton.contentHorizontalAlignment = .trailing
        languageButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let timedText = resolvedTimedText else {
                    completion([])
                    return
                }
                let current = resolvedTrackIndex
                completion(timedText.tracks.enumerated().map { index, track in
                    UIAction(title: track.languageLabel, state: index == current ? .on : .off) { [weak self] _ in
                        self?.selectTrack(index)
                    }
                })
            },
        ])
        let languageSlot = UIView()
        languageButton.translatesAutoresizingMaskIntoConstraints = false
        languageSlot.addSubview(languageButton)
        NSLayoutConstraint.activate([
            languageSlot.widthAnchor.constraint(equalToConstant: 72),
            languageButton.leadingAnchor.constraint(equalTo: languageSlot.leadingAnchor),
            languageButton.trailingAnchor.constraint(equalTo: languageSlot.trailingAnchor),
            languageButton.centerYAnchor.constraint(equalTo: languageSlot.centerYAnchor),
            languageButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        shareButton.accessibilityIdentifier = "audioLyrics.share"
        shareButton.onFailure = { [weak self] in self?.presentShareFailure() }

        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 8
        for subview in [backButton, doneButton, titleLabel, stopButton, languageSlot, shareButton] {
            headerStack.addArrangedSubview(subview)
        }
    }

    private func applyChrome() {
        let config = configuration
        backButton.isHidden = !config.usesNavigationBackButton
        doneButton.isHidden = config.usesNavigationBackButton || !config.showsCloseButton
        titleLabel.text = config.titlePresentation.showsInternalTitle ? config.title : nil
        // File browser embeds this player with the shared service and no close
        // control. Stop belongs only on presented Now Playing chrome so it cannot
        // kill unrelated playback.
        stopButton.isHidden = !(config.showsCloseButton || config.usesNavigationBackButton) || config.audioPlayer == nil
        shareButton.isHidden = config.shareFileData == nil
        shareButton.filename = config.title
        shareButton.loadData = config.shareFileData

        if config.usesNavigationBackButton, backSwipe == nil {
            let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.leave() }
            installer.install(on: view)
            backSwipe = installer
        }
    }

    private func applyLanguageControl() {
        guard let timedText = resolvedTimedText, timedText.showsLanguageControl else {
            languageButton.isHidden = true
            return
        }
        let label = timedText.tracks.indices.contains(resolvedTrackIndex)
            ? timedText.tracks[resolvedTrackIndex].languageLabel
            : String(localized: "Language")
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(
            label,
            attributes: AttributeContainer([.font: AudioPlayerChromeStyle.font(.caption1, weight: .semibold)])
        )
        configuration.baseForegroundColor = style.purple
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = .zero
        languageButton.configuration = configuration
        languageButton.accessibilityValue = label
        languageButton.isHidden = false
    }

    private func applyTransport() {
        let config = configuration
        let playbackText = { [weak self] in self?.playbackTimedText }
        transport.apply(.init(
            itemID: config.itemID,
            audioPlayer: config.audioPlayer,
            play: { config.play(playbackText()) },
            openFile: config.openFile
        ))
    }

    private func leave() {
        if let dismiss = configuration.dismiss {
            dismiss()
        } else {
            dismiss(animated: true)
        }
    }

    private func presentShareFailure() {
        let alert = UIAlertController(
            title: String(localized: "Unable to Share File"),
            message: String(localized: "The file could not be downloaded. Please try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Body

    private func buildBody() -> UIView {
        emptyLabel.text = String(localized: "No lyrics")
        emptyLabel.font = AudioPlayerChromeStyle.font(.title2)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.accessibilityIdentifier = "audioLyrics.empty"

        transcript.onSelectLine = { [weak self] index in self?.jump(toLine: index) }
        transcript.onUserScroll = { [weak self] in self?.setFollowsPlayback(false) }
        transcriptFade.install(transcript)

        followButton.accessibilityIdentifier = "audioLyrics.followCurrentLine"
        followButton.isHidden = true
        followButton.alpha = 0
        followButton.addAction(UIAction { [weak self] _ in self?.setFollowsPlayback(true) }, for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [castStrip, transcriptFade])
        column.axis = .vertical

        let body = UIView()
        for subview in [column, emptyLabel, followButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: body.topAnchor),
            column.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            followButton.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            body.bottomAnchor.constraint(equalTo: followButton.bottomAnchor, constant: 20),
        ])
        return body
    }
}

/// Soft top and bottom edges so lines fade under the cast strip and transport instead of clipping.
private final class AudioTranscriptFadeView: UIView {
    private let fade = CAGradientLayer()

    func install(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        layer.mask = fade
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = bounds.height > 0 ? min(0.5, 16 / bounds.height) : 0
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
    }
}

/// Speakers in order of first line; the current speaker's chip is lit.
final class AudioCastStripView: UIView {
    /// Applies to chips built by the next ``setCast(_:)``.
    var style: AudioPlayerChromeStyle
    private var chips: [Chip] = []
    private var speaking: String?
    private var measuredHeight: CGFloat = 0

    private static let spacing: CGFloat = 8
    private static let insets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)

    init(style: AudioPlayerChromeStyle) {
        self.style = style
        super.init(frame: .zero)
        accessibilityContainerType = .list
        accessibilityLabel = String(localized: "Cast")
        accessibilityIdentifier = "audioLyrics.cast"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCast(_ members: [(name: String, color: UIColor)]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = members.map { Chip(name: $0.name, color: $0.color, style: style) }
        chips.forEach(addSubview)
        speaking = nil
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    func setSpeaking(_ name: String?) {
        guard name != speaking else { return }
        speaking = name
        let animated = window != nil
        for chip in chips {
            chip.setSpeaking(chip.name == name, animated: animated)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = layoutChips(width: bounds.width, apply: true)
        if height != measuredHeight {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layoutChips(width: size.width, apply: false))
    }

    /// Flow layout: chips wrap to a new row when the current one is full.
    private func layoutChips(width: CGFloat, apply: Bool) -> CGFloat {
        guard !chips.isEmpty, width > 0 else { return 0 }
        let available = width - Self.insets.left - Self.insets.right
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for chip in chips {
            var size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            size.width = min(size.width, available)
            if x > 0, x + size.width > available {
                x = 0
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            if apply {
                chip.frame = CGRect(x: Self.insets.left + x, y: Self.insets.top + y, width: size.width, height: size.height)
            }
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        return Self.insets.top + y + rowHeight + Self.insets.bottom
    }

    private final class Chip: UIView {
        let name: String
        private let color: UIColor
        private let style: AudioPlayerChromeStyle
        private let label = UILabel()

        init(name: String, color: UIColor, style: AudioPlayerChromeStyle) {
            self.name = name
            self.color = color
            self.style = style
            super.init(frame: .zero)
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 4
            label.text = name
            label.adjustsFontForContentSizeCategory = true
            let row = UIStackView(arrangedSubviews: [dot, label])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 10),
                row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: 5),
            ])
            layer.cornerCurve = .continuous
            isAccessibilityElement = true
            accessibilityLabel = name
            setSpeaking(false, animated: false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.height / 2
        }

        func setSpeaking(_ isSpeaking: Bool, animated: Bool) {
            label.font = AudioPlayerChromeStyle.font(.footnote, weight: isSpeaking ? .semibold : .regular)
            accessibilityTraits = isSpeaking ? .selected : []
            let apply = {
                self.label.textColor = isSpeaking ? self.style.foreground : self.style.dimmed
                self.backgroundColor = isSpeaking
                    ? self.color.withAlphaComponent(0.22)
                    : self.style.highlight.withAlphaComponent(0.7)
                self.layer.borderColor = self.color.cgColor
                self.layer.borderWidth = isSpeaking ? 1 : 0
            }
            if animated {
                UIView.animate(withDuration: 0.2, animations: apply)
            } else {
                apply()
            }
        }
    }
}

/// Share button for media whose bytes are fetched only when the reader asks to share.
final class AudioFileShareButton: UIButton {
    var filename = ""
    var loadData: (() async throws -> Data)?
    var onFailure: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isLoading = false

    init(style: AudioPlayerChromeStyle) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "square.and.arrow.up")
        configuration.contentInsets = .zero
        self.configuration = configuration
        accessibilityLabel = String(localized: "Share")
        apply(style)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ style: AudioPlayerChromeStyle) {
        configuration?.baseForegroundColor = style.dimmed
        spinner.color = style.cyan
    }

    private func share() {
        guard !isLoading, let loadData else { return }
        setLoading(true)
        Task { [weak self] in
            defer { self?.setLoading(false) }
            do {
                let data = try await loadData()
                guard let self else { return }
                let item = FileShareService.fileShareItem(data: data, filename: filename)
                FileSharePresenter.presentActivityController(item: item, sourceView: self)
            } catch is CancellationError {
                return
            } catch {
                self?.onFailure?()
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        isLoading = loading
        isEnabled = !loading
        configuration?.image = loading ? nil : UIImage(systemName: "square.and.arrow.up")
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}
