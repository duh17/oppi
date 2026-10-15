import SwiftUI
import UIKit

/// Theme snapshot and type scale for the UIKit audio player chrome.
struct AudioPlayerChromeStyle {
    let background: UIColor
    let highlight: UIColor
    let foreground: UIColor
    let dimmed: UIColor
    let comment: UIColor
    let cyan: UIColor
    let purple: UIColor
    let yellow: UIColor
    let orange: UIColor
    /// Speaker accents without an authored WebVTT color, in cast order.
    let speakerAccents: [UIColor]

    init(_ palette: ThemePalette = ThemeRuntimeState.currentPalette()) {
        background = UIColor(palette.bg)
        highlight = UIColor(palette.bgHighlight)
        foreground = UIColor(palette.fg)
        dimmed = UIColor(palette.fgDim)
        comment = UIColor(palette.comment)
        cyan = UIColor(palette.cyan)
        purple = UIColor(palette.purple)
        yellow = UIColor(palette.yellow)
        orange = UIColor(palette.orange)
        speakerAccents = [palette.orange, palette.blue, palette.green, palette.purple, palette.red, palette.cyan, palette.yellow]
            .map { UIColor($0) }
    }

    /// Dynamic Type font at a text style with an explicit weight.
    static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let descriptor = base.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: 0))
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    static func symbol(_ name: String, style: UIFont.TextStyle, weight: UIFont.Weight) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font(style, weight: weight)))
    }

    /// Capsule chip used for header and listening controls.
    func capsuleConfiguration(
        title: String,
        symbol: String? = nil,
        font: UIFont,
        foreground: UIColor,
        fillAlpha: CGFloat = 0.9,
        insets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
    ) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))
        if let symbol {
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
            configuration.imagePadding = 6
        }
        configuration.baseForegroundColor = foreground
        configuration.contentInsets = insets
        configuration.cornerStyle = .capsule
        configuration.background.backgroundColor = highlight.withAlphaComponent(fillAlpha)
        configuration.titleLineBreakMode = .byTruncatingTail
        return configuration
    }
}

/// Fixed-size icon button for transport and header actions.
@MainActor
func makeAudioIconButton(
    symbol: String,
    pointSize: CGFloat,
    tint: UIColor,
    size: CGFloat = 44,
    label: String,
    identifier: String
) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = AudioPlayerChromeStyle.symbol(symbol, pointSize: pointSize)
    configuration.baseForegroundColor = tint
    configuration.contentInsets = .zero
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = label
    button.accessibilityIdentifier = identifier
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: size),
        button.heightAnchor.constraint(equalToConstant: size),
    ])
    return button
}

/// Shared seek and transport controls for full-screen and expanded Now Playing.
///
/// Reads `AudioPlayerService` inside `updateProperties()`, so UIKit observation
/// tracking repaints it whenever playback state changes.
final class AudioPlaybackTransportView: UIView {
    struct Configuration {
        var itemID: String
        var audioPlayer: AudioPlayerService?
        var play: () -> Void
        var openFile: (() -> Void)?
    }

    let density: AudioPlaybackTransportDensity
    let accessibilityPrefix: String
    private var configuration: Configuration
    private var style = AudioPlayerChromeStyle()
    /// Text size the current button configurations were built for.
    private var styledContentSizeCategory: UIContentSizeCategory?

    private var isScrubbing = false
    private var scrubFraction: Double = 0
    /// Which optional rows were visible at the last render; a change re-measures SwiftUI hosts.
    private var visibleRows: [Bool] = []
    private var renderedChips: ListeningChips?
    private var renderedPlayState: (action: AudioPlaybackControlAction, isPlaying: Bool)?

    private let stack = UIStackView()
    private let chapterTitleLabel = UILabel()
    private let seekBar = AudioPlaybackSeekBar()
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private let controls = UIStackView()
    private lazy var previousChapterButton = chapterButton(forward: false)
    private lazy var nextChapterButton = chapterButton(forward: true)
    private lazy var skipBackButton = skipButton(
        interval: -AudioPlayerService.skipInterval,
        symbol: "gobackward.15",
        label: String(localized: "Skip back 15 seconds"),
        identifier: "\(accessibilityPrefix).skipBack"
    )
    private lazy var skipForwardButton = skipButton(
        interval: AudioPlayerService.skipInterval,
        symbol: "goforward.15",
        label: String(localized: "Skip forward 15 seconds"),
        identifier: "\(accessibilityPrefix).skipForward"
    )
    private lazy var playButton = makeAudioIconButton(
        symbol: "play.fill",
        pointSize: density.playSymbolSize,
        tint: style.foreground,
        size: density.playSize,
        label: String(localized: "Play"),
        identifier: "\(accessibilityPrefix).playPause"
    )
    private lazy var loadingControl = AudioLoadingCancelView(style: style)
    private let failureLabel = UILabel()
    private let listeningRow = UIStackView()
    private let speedButton = UIButton(configuration: .plain())
    private let chaptersButton = UIButton(configuration: .plain())
    private let sleepButton = UIButton(configuration: .plain())
    private let openFileButton = UIButton(configuration: .plain())
    private lazy var controlsRow = Self.centered(controls)
    private lazy var listeningContainer = Self.centered(listeningRow)
    private lazy var openFileContainer = Self.centered(openFileButton)

    init(
        density: AudioPlaybackTransportDensity,
        accessibilityPrefix: String = "audioLyrics",
        configuration: Configuration = Configuration(itemID: "", audioPlayer: nil, play: {}, openFile: nil)
    ) {
        self.density = density
        self.accessibilityPrefix = accessibilityPrefix
        self.configuration = configuration
        super.init(frame: .zero)
        buildHierarchy()
        applyStyle()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .oppiThemeDidChange, object: nil)
    }

    @objc private func themeDidChange() {
        style = AudioPlayerChromeStyle()
        applyStyle()
    }

    /// Colors and button configurations from the current theme and text size.
    private func applyStyle() {
        styledContentSizeCategory = traitCollection.preferredContentSizeCategory
        chapterTitleLabel.textColor = style.dimmed
        seekBar.trackColor = style.comment.withAlphaComponent(0.35)
        seekBar.fillColor = style.foreground
        elapsedLabel.textColor = style.comment
        durationLabel.textColor = style.comment
        for button in [previousChapterButton, skipBackButton, playButton, skipForwardButton, nextChapterButton] {
            button.configuration?.baseForegroundColor = style.foreground
        }
        loadingControl.apply(style)
        chaptersButton.configuration = style.capsuleConfiguration(
            title: String(localized: "Chapters"),
            symbol: "list.bullet",
            font: Self.chipFont(),
            foreground: style.foreground
        )
        var openFile = UIButton.Configuration.plain()
        openFile.attributedTitle = AttributedString(
            String(localized: "Open file"),
            attributes: AttributeContainer([.font: AudioPlayerChromeStyle.font(.subheadline)])
        )
        openFile.baseForegroundColor = style.purple
        openFileButton.configuration = openFile
        // The failure line, play glyph, and chips repaint from state on the next pass.
        renderedChips = nil
        renderedPlayState = nil
        setNeedsUpdateProperties()
    }

    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        setNeedsUpdateProperties()
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        chapterTitleLabel.font = AudioPlayerChromeStyle.font(.subheadline, weight: .semibold)
        chapterTitleLabel.adjustsFontForContentSizeCategory = true
        chapterTitleLabel.accessibilityIdentifier = "\(accessibilityPrefix).chapterTitle"

        seekBar.accessibilityIdentifier = "\(accessibilityPrefix).seek"
        seekBar.onScrub = { [weak self] fraction in
            guard let self else { return }
            isScrubbing = true
            scrubFraction = fraction
            setNeedsUpdateProperties()
        }
        seekBar.onCommit = { [weak self] fraction in self?.commitSeek(fraction) }
        seekBar.onCancel = { [weak self] in
            self?.isScrubbing = false
            self?.setNeedsUpdateProperties()
        }

        for label in [elapsedLabel, durationLabel] {
            label.font = AudioPlayerChromeStyle.font(.caption1)
            label.adjustsFontForContentSizeCategory = true
        }
        let times = UIStackView(arrangedSubviews: [elapsedLabel, durationLabel])
        times.axis = .horizontal
        times.distribution = .equalSpacing

        let info = UIStackView(arrangedSubviews: [chapterTitleLabel, seekBar, times])
        info.axis = .vertical
        info.spacing = 6

        playButton.addSubview(loadingControl)
        loadingControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingControl.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loadingControl.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .primaryActionTriggered)

        controls.axis = .horizontal
        controls.alignment = .center
        for button in [previousChapterButton, skipBackButton, playButton, skipForwardButton, nextChapterButton] {
            controls.addArrangedSubview(button)
        }

        failureLabel.font = AudioPlayerChromeStyle.font(.footnote)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.accessibilityIdentifier = "\(accessibilityPrefix).playbackFailure"

        speedButton.accessibilityLabel = String(localized: "Playback Speed")
        speedButton.accessibilityIdentifier = "\(accessibilityPrefix).speed"
        speedButton.menu = speedMenu()
        chaptersButton.accessibilityIdentifier = "\(accessibilityPrefix).chapters"
        chaptersButton.menu = chapterMenu()
        sleepButton.accessibilityLabel = String(localized: "Sleep Timer")
        sleepButton.accessibilityIdentifier = "\(accessibilityPrefix).sleepTimer"
        sleepButton.menu = sleepMenu()
        for button in [speedButton, chaptersButton, sleepButton] {
            button.showsMenuAsPrimaryAction = true
            listeningRow.addArrangedSubview(button)
        }
        listeningRow.axis = .horizontal
        listeningRow.spacing = 10

        openFileButton.addAction(UIAction { [weak self] _ in self?.configuration.openFile?() }, for: .primaryActionTriggered)

        stack.axis = .vertical
        stack.spacing = density.stackSpacing
        for row in [info, controlsRow, failureLabel, listeningContainer, openFileContainer] {
            stack.addArrangedSubview(row)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: density.horizontalPadding),
            trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: density.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: density.topPadding),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: density.bottomPadding),
        ])
    }

    private static func chipFont() -> UIFont {
        AudioPlayerChromeStyle.font(.subheadline, weight: .semibold)
    }

    private static func centered(_ content: UIView) -> UIView {
        let container = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func skipButton(interval: TimeInterval, symbol: String, label: String, identifier: String) -> UIButton {
        let button = makeAudioIconButton(
            symbol: symbol,
            pointSize: 24,
            tint: style.foreground,
            label: label,
            identifier: identifier
        )
        button.addAction(UIAction { [weak self] _ in
            guard let self, matchesPlayback else { return }
            configuration.audioPlayer?.skip(by: interval)
        }, for: .primaryActionTriggered)
        return button
    }

    private func chapterButton(forward: Bool) -> UIButton {
        let button = makeAudioIconButton(
            symbol: forward ? "forward.end.fill" : "backward.end.fill",
            pointSize: 20,
            tint: style.foreground,
            label: forward ? String(localized: "Next Chapter") : String(localized: "Previous Chapter"),
            identifier: "\(accessibilityPrefix).\(forward ? "nextChapter" : "previousChapter")"
        )
        button.addAction(UIAction { [weak self] _ in
            self?.configuration.audioPlayer?.skipChapter(forward: forward)
        }, for: .primaryActionTriggered)
        return button
    }

    // MARK: - Playback state

    private var matchesPlayback: Bool {
        guard let audioPlayer = configuration.audioPlayer else { return false }
        return audioPlayer.playingItemID == configuration.itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: configuration.itemID)
    }

    private var showsListeningControls: Bool { density == .fullScreen }

    private var controlAction: AudioPlaybackControlAction {
        AudioPlaybackControlAction.resolve(
            isLoading: configuration.audioPlayer?.loadingItemID == configuration.itemID,
            isActive: matchesPlayback,
            isPaused: configuration.audioPlayer?.isPaused == true
        )
    }

    override func updateProperties() {
        super.updateProperties()
        // Button configuration titles do not follow Dynamic Type on their own.
        // Reading the category here makes UIKit re-run this pass when it changes.
        if traitCollection.preferredContentSizeCategory != styledContentSizeCategory {
            applyStyle()
        }
        let player = configuration.audioPlayer
        let matches = matchesPlayback
        let duration = matches ? player?.duration : nil
        let playbackTime = matches ? player?.currentTime ?? 0 : 0
        let elapsed = isScrubbing
            ? AudioPlaybackSeek.time(forFraction: scrubFraction, duration: duration) ?? playbackTime
            : playbackTime
        let isSeekable = matches && AudioPlaybackSeek.isSeekable(duration: duration)
        let chapters = matches ? player?.chapters ?? [] : []
        let hasChapterControls = showsListeningControls && !chapters.isEmpty

        let chapterTitle = showsListeningControls
            ? AudioChapters.index(in: chapters, at: elapsed).map { chapters[$0].title }
            : nil
        chapterTitleLabel.text = chapterTitle
        chapterTitleLabel.isHidden = chapterTitle == nil

        seekBar.isSeekable = isSeekable
        seekBar.fraction = isScrubbing ? scrubFraction : AudioPlaybackSeek.fraction(elapsed: elapsed, duration: duration)
        elapsedLabel.text = AudioPlaybackTimeFormatting.clock(elapsed)
        durationLabel.text = AudioPlaybackTimeFormatting.clock(duration)

        controls.spacing = hasChapterControls ? 16 : density.controlSpacing
        previousChapterButton.isHidden = !hasChapterControls
        nextChapterButton.isHidden = !hasChapterControls
        for button in [skipBackButton, skipForwardButton, previousChapterButton, nextChapterButton] {
            button.isEnabled = isSeekable
            button.alpha = isSeekable ? 1 : 0.45
        }
        renderPlayButton(isPlaying: matches && player?.isPaused == false)

        if let failure = player?.playbackFailure, failure.itemID == configuration.itemID {
            failureLabel.attributedText = Self.failureText(
                String(localized: "Can't play this audio. \(failure.reason)"),
                font: failureLabel.font,
                color: style.yellow
            )
            failureLabel.isHidden = false
        } else {
            failureLabel.isHidden = true
        }

        listeningContainer.isHidden = !showsListeningControls
        if showsListeningControls {
            renderListeningControls(player: player, matches: matches, hasChapters: !chapters.isEmpty)
        }
        openFileContainer.isHidden = matches || configuration.openFile == nil

        let rows = [chapterTitleLabel.isHidden, failureLabel.isHidden, listeningContainer.isHidden, openFileContainer.isHidden]
        if rows != visibleRows {
            visibleRows = rows
            invalidateIntrinsicContentSize()
        }
    }

    private func renderPlayButton(isPlaying: Bool) {
        let action = controlAction
        guard renderedPlayState?.action != action || renderedPlayState?.isPlaying != isPlaying else { return }
        renderedPlayState = (action, isPlaying)
        let isLoading = action == .cancelLoading
        loadingControl.setVisible(isLoading)
        playButton.configuration?.image = isLoading
            ? nil
            : AudioPlayerChromeStyle.symbol(isPlaying ? "pause.fill" : "play.fill", pointSize: density.playSymbolSize)
        playButton.accessibilityLabel = switch action {
        case .start, .resume: String(localized: "Play")
        case .cancelLoading: String(localized: "Cancel Loading")
        case .pause: String(localized: "Pause")
        }
    }

    private func renderListeningControls(player: AudioPlayerService?, matches: Bool, hasChapters: Bool) {
        chaptersButton.isHidden = !hasChapters
        sleepButton.isHidden = !matches

        // Chip labels change rarely; skip rebuilding configurations on playback ticks.
        let rate = player?.playbackRate ?? 1
        let timer = player?.sleepTimer
        let chips = ListeningChips(
            rateLabel: AudioPlaybackRate.label(rate),
            isRateActive: rate != 1,
            sleepLabel: Self.sleepLabel(timer),
            isSleepActive: timer != nil
        )
        guard chips != renderedChips else { return }
        renderedChips = chips
        speedButton.configuration = style.capsuleConfiguration(
            title: chips.rateLabel,
            font: Self.chipFont(),
            foreground: chips.isRateActive ? style.purple : style.foreground
        )
        speedButton.accessibilityValue = chips.rateLabel
        sleepButton.configuration = style.capsuleConfiguration(
            title: chips.sleepLabel,
            symbol: "moon.zzz",
            font: Self.chipFont(),
            foreground: chips.isSleepActive ? style.purple : style.foreground
        )
        sleepButton.accessibilityValue = chips.isSleepActive ? chips.sleepLabel : String(localized: "Off")
    }

    private struct ListeningChips: Equatable {
        var rateLabel: String
        var isRateActive: Bool
        var sleepLabel: String
        var isSleepActive: Bool
    }

    private static func sleepLabel(_ timer: AudioSleepTimer?) -> String {
        guard let timer else { return String(localized: "Sleep") }
        if timer.option == .endOfChapter { return String(localized: "Chapter End") }
        return AudioPlaybackTimeFormatting.clock(timer.remainingTime(now: Date()))
    }

    private static func failureText(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let image = UIImage(systemName: "exclamationmark.triangle", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: text))
        result.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Menus

    /// Menu rows are built when the menu opens from the player's current state, and
    /// each row captures its own value, so a menu can never index a list that
    /// playback has since replaced or cleared.
    private func deferredMenu(_ build: @escaping @MainActor (AudioPlayerService) -> [UIMenuElement]) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let player = self?.configuration.audioPlayer else {
                    completion([])
                    return
                }
                completion(build(player))
            },
        ])
    }

    private func speedMenu() -> UIMenu {
        deferredMenu { player in
            AudioPlaybackRate.options.map { option in
                UIAction(
                    title: AudioPlaybackRate.label(option),
                    state: option == player.playbackRate ? .on : .off
                ) { _ in
                    player.setPlaybackRate(option)
                }
            }
        }
    }

    private func chapterMenu() -> UIMenu {
        deferredMenu { [weak self] player in
            guard let self, matchesPlayback else { return [] }
            let chapters = player.chapters
            let current = AudioChapters.index(in: chapters, at: player.currentTime)
            return chapters.enumerated().map { index, chapter in
                UIAction(title: chapter.title, state: index == current ? .on : .off) { _ in
                    player.seek(to: chapter.start)
                }
            }
        }
    }

    private func sleepMenu() -> UIMenu {
        deferredMenu { player in
            var items: [UIMenuElement] = AudioSleepTimer.minuteOptions.map { minutes in
                UIAction(title: String(localized: "\(minutes) Minutes")) { _ in
                    player.setSleepTimer(.minutes(minutes))
                }
            }
            if !player.chapters.isEmpty {
                items.append(UIAction(title: String(localized: "End of Chapter")) { _ in
                    player.setSleepTimer(.endOfChapter)
                })
            }
            if player.sleepTimer != nil {
                items.append(UIAction(title: String(localized: "Turn Off Timer"), attributes: .destructive) { _ in
                    player.setSleepTimer(nil)
                })
            }
            return items
        }
    }

    // MARK: - Actions

    private func commitSeek(_ fraction: Double) {
        isScrubbing = false
        scrubFraction = fraction
        setNeedsUpdateProperties()
        let duration = matchesPlayback ? configuration.audioPlayer?.duration : nil
        guard matchesPlayback,
              let time = AudioPlaybackSeek.time(forFraction: fraction, duration: duration) else {
            return
        }
        configuration.audioPlayer?.seek(to: time)
    }

    private func togglePlay() {
        switch controlAction {
        case .start:
            configuration.play()
        case .cancelLoading:
            configuration.audioPlayer?.stop()
        case .pause:
            configuration.audioPlayer?.pause()
        case .resume:
            configuration.audioPlayer?.resume()
        }
    }
}

/// Spinner with a small cancel glyph, shown in the play slot while audio loads.
final class AudioLoadingCancelView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let glyph = UIImageView(image: AudioPlayerChromeStyle.symbol(
        AudioLoadingCancelControl.cancelSymbolName,
        pointSize: 8,
        weight: .bold
    ))

    init(style: AudioPlayerChromeStyle) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        apply(style)
        for view in [spinner, glyph] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalTo: spinner.widthAnchor),
            heightAnchor.constraint(equalTo: spinner.heightAnchor),
        ])
        setVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ style: AudioPlayerChromeStyle) {
        spinner.color = style.comment
        glyph.tintColor = style.foreground
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if visible { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}

/// 44pt track that scrubs on drag and tap-to-position. `UISlider` is thumb-only.
final class AudioPlaybackSeekBar: UIControl {
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            setNeedsLayout()
            accessibilityValue = Self.percentValue(fraction)
        }
    }

    var isSeekable = false {
        didSet {
            guard isSeekable != oldValue else { return }
            isUserInteractionEnabled = isSeekable
            alpha = isSeekable ? 1 : 0.55
            if !isSeekable, isTracking {
                cancelTracking(with: nil)
            }
            if !isSeekable { releaseClaim() }
        }
    }

    var trackColor: UIColor = .systemGray { didSet { track.backgroundColor = trackColor } }
    var fillColor: UIColor = .label {
        didSet {
            fill.backgroundColor = fillColor
            thumb.backgroundColor = fillColor
        }
    }

    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    var onCancel: (() -> Void)?

    private let track = UIView()
    private let fill = UIView()
    private let thumb = UIView()
    /// Keeps a SwiftUI parent back-swipe from popping the host mid-scrub.
    private var scrubClaim: BackSwipeExclusiveClaim?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [track, fill, thumb] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        track.layer.cornerRadius = 2
        fill.layer.cornerRadius = 2
        thumb.layer.cornerRadius = 6
        isUserInteractionEnabled = false
        alpha = 0.55
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Playback position")
        accessibilityTraits = .adjustable
        accessibilityValue = Self.percentValue(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let clamped = CGFloat(min(1, max(0, fraction)))
        let midY = bounds.midY
        track.frame = CGRect(x: 0, y: midY - 2, width: width, height: 4)
        fill.frame = CGRect(x: 0, y: midY - 2, width: width * clamped, height: 4)
        thumb.frame = CGRect(x: width * clamped - 6, y: midY - 6, width: 12, height: 12)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseClaim() }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isSeekable else { return false }
        if scrubClaim == nil {
            scrubClaim = HorizontalBackSwipeGesturePolicy.acquireExclusiveClaim()
        }
        onScrub?(fraction(for: touch))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        onScrub?(fraction(for: touch))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        releaseClaim()
        if let touch {
            onCommit?(fraction(for: touch))
        } else {
            onCancel?()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        releaseClaim()
        onCancel?()
    }

    override func accessibilityIncrement() {
        guard isSeekable else { return }
        onCommit?(min(1, fraction + 0.05))
    }

    override func accessibilityDecrement() {
        guard isSeekable else { return }
        onCommit?(max(0, fraction - 0.05))
    }

    private func fraction(for touch: UITouch) -> Double {
        guard bounds.width > 0 else { return 0 }
        return min(1, max(0, Double(touch.location(in: self).x / bounds.width)))
    }

    private func releaseClaim() {
        if let claim = scrubClaim {
            HorizontalBackSwipeGesturePolicy.releaseExclusiveClaim(claim)
            scrubClaim = nil
        }
    }

    private static func percentValue(_ fraction: Double) -> String {
        String(localized: "\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

/// SwiftUI host for the UIKit transport, used by the expanded Now Playing drawer.
struct AudioPlaybackTransportControls: UIViewRepresentable {
    let itemID: String
    let audioPlayer: AudioPlayerService?
    let play: () -> Void
    var openFile: (() -> Void)? = nil
    var density: AudioPlaybackTransportDensity = .fullScreen
    var accessibilityPrefix = "audioLyrics"

    func makeUIView(context: Context) -> AudioPlaybackTransportView {
        AudioPlaybackTransportView(density: density, accessibilityPrefix: accessibilityPrefix)
    }

    func updateUIView(_ view: AudioPlaybackTransportView, context: Context) {
        view.apply(.init(itemID: itemID, audioPlayer: audioPlayer, play: play, openFile: openFile))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AudioPlaybackTransportView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        uiView.updatePropertiesIfNeeded()
        let height = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return CGSize(width: width, height: height)
    }
}
