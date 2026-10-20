import SwiftUI
import UIKit

enum InAppNowPlayingChrome {
    enum SessionListToolbar: Equatable {
        case searchField
        case minimizedSearchWithNowPlaying
        case expandedSearchWithCompactNowPlaying

        var showsNowPlayingPill: Bool {
            self != .searchField
        }

        var parksNowPlayingNextToCompose: Bool {
            self == .expandedSearchWithCompactNowPlaying
        }

        var avoidsHidingContentWhileSearching: Bool {
            showsNowPlayingPill
        }

        var pillDensity: PillDensity {
            parksNowPlayingNextToCompose ? .sessionListCompact : .sessionList
        }
    }

    enum PillDensity: Equatable {
        case chat
        case sessionList
        case sessionListCompact

        var showsTitle: Bool {
            self != .sessionListCompact
        }

        var titleMinWidth: CGFloat {
            self == .chat ? 160 : 0
        }

        var titleMaxWidth: CGFloat {
            switch self {
            case .chat: return 240
            case .sessionList: return 160
            case .sessionListCompact: return 0
            }
        }

        var visualHeight: CGFloat { ExtensionStripPillMetrics.visualHeight }
        var playPauseHitSize: CGFloat { 44 }
        var stopHitSize: CGFloat { 44 }
    }

    static let directSpeakPlaybackPrefix = "audio-stream-"

    static func playbackItemID(playingItemID: String?, loadingItemID: String?) -> String? {
        if let playingItemID, !playingItemID.isEmpty { return playingItemID }
        if let loadingItemID, !loadingItemID.isEmpty { return loadingItemID }
        return nil
    }

    static func shouldShowChatPill(
        hasActivePlayback: Bool,
        playbackItemID: String?,
        visibleStripItemIDs: Set<String>
    ) -> Bool {
        guard hasActivePlayback else { return false }
        guard let playbackItemID else { return true }
        return !visibleStripItemIDs.contains { matchesPlayback(playbackItemID, stripItemID: $0) }
    }

    static func sessionListToolbar(
        hasActivePlayback: Bool,
        isSearchPresented: Bool = false
    ) -> SessionListToolbar {
        guard hasActivePlayback else { return .searchField }
        return isSearchPresented
            ? .expandedSearchWithCompactNowPlaying
            : .minimizedSearchWithNowPlaying
    }

    enum TitleAction: Equatable {
        case expandOrCollapse
        case openFullScreen
    }

    /// In-session: tap expands, double-tap opens fullscreen. Inbox: tap opens fullscreen.
    static func titleAction(tapCount: Int, expandsOnTap: Bool) -> TitleAction? {
        guard tapCount == 1 || tapCount == 2 else { return nil }
        if expandsOnTap {
            return tapCount == 1 ? .expandOrCollapse : .openFullScreen
        }
        return .openFullScreen
    }

    static func shouldDismissPlayer(hasActivePlayback: Bool) -> Bool {
        !hasActivePlayback
    }

    enum SubtitlePresentation: Equatable {
        case loading
        case unavailable
        case gap
        case cue(String)
    }

    static func subtitlePresentation(
        in timedText: TimedText.LoadResult,
        at time: TimeInterval,
        isLoading: Bool
    ) -> SubtitlePresentation {
        if let subtitle = currentSubtitle(in: timedText, at: time) {
            return .cue(subtitle)
        }
        if isLoading, timedText.tracks.isEmpty {
            return .loading
        }
        if timedText.selected != nil {
            return .gap
        }
        return .unavailable
    }

    static func currentSubtitle(
        in timedText: TimedText.LoadResult,
        at time: TimeInterval
    ) -> String? {
        guard let track = timedText.selected,
              let cue = TimedText.currentCue(in: track.cues, at: time) else {
            return nil
        }
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func matchesPlayback(_ playbackItemID: String, stripItemID: String) -> Bool {
        if playbackItemID == stripItemID { return true }
        if playbackItemID == directSpeakPlaybackPrefix + stripItemID { return true }
        return false
    }

    @MainActor
    static func visibleStripItemIDs(
        from searchRoots: [UIView],
        in coordinateSpace: UIView,
        unobstructedRect: CGRect
    ) -> Set<String> {
        var ids = Set<String>()
        for searchRoot in searchRoots {
            collectStripItemIDs(
                from: searchRoot,
                root: coordinateSpace,
                unobstructedRect: unobstructedRect,
                into: &ids
            )
        }
        return ids
    }

    @MainActor
    private static func collectStripItemIDs(
        from view: UIView,
        root: UIView,
        unobstructedRect: CGRect,
        into ids: inout Set<String>
    ) {
        if let strip = view as? NativeAudioPlayerStripView, let itemID = strip.playbackItemID {
            let frameInRoot = view.convert(view.bounds, to: root)
            if frameInRoot.intersects(unobstructedRect) {
                ids.insert(itemID)
            }
        }
        for subview in view.subviews {
            collectStripItemIDs(
                from: subview,
                root: root,
                unobstructedRect: unobstructedRect,
                into: &ids
            )
        }
    }
}

struct InAppNowPlayingPlayerScreen: View {
    let audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AudioLyricsPlayerView(
            title: audioPlayer.nowPlayingPresentation?.title ?? "Now Playing",
            lyrics: nil,
            itemID: audioPlayer.playingItemID ?? audioPlayer.loadingItemID ?? "",
            audioPlayer: audioPlayer,
            play: { _ in
                if audioPlayer.isPaused {
                    audioPlayer.resume()
                }
            },
            openFile: nil,
            autoplayOnAppear: false,
            showsCloseButton: false,
            usesNavigationBackButton: true,
            timedText: audioPlayer.nowPlayingTimedText
        )
        .onAppear(perform: dismissIfPlaybackEnded)
        .onChange(of: audioPlayer.hasActivePlayback) { _, _ in
            dismissIfPlaybackEnded()
        }
    }

    private func dismissIfPlaybackEnded() {
        if InAppNowPlayingChrome.shouldDismissPlayer(
            hasActivePlayback: audioPlayer.hasActivePlayback
        ) {
            dismiss()
        }
    }
}

/// The now-playing pill: play/pause (a cancel spinner while loading), the
/// title, and stop. Reads `AudioPlayerService` in `updateProperties()`, so it
/// follows playback on its own. In the session lists' bottom bar a tap on the
/// title opens the full-screen player. On the chat's strip (`.chat`, with
/// `onExpand`) it draws the strip-pill surface at the strip pills' height:
/// a tap on the title opens or closes the player drawer, a double tap opens
/// the full-screen player, and VoiceOver gets Open Full Screen as an action.
final class InAppNowPlayingPillView: UIView {
    private var audioPlayer: AudioPlayerService
    private let onExpand: (() -> Void)?
    private let onOpen: () -> Void
    private var density: InAppNowPlayingChrome.PillDensity
    private var isExpanded = false

    private let surface = ElevatedSurfaceView(shape: .capsule)
    private let stack = UIStackView()
    private let playPause = UIButton(type: .custom)
    private let loading = AudioLoadingCancelView(style: AudioPlayerChromeStyle())
    private let titleArea = TitleArea()
    private let titleRow = UIStackView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let titleMinWidth: NSLayoutConstraint
    private let titleMaxWidth: NSLayoutConstraint
    private let stop = UIButton(type: .custom)

    init(
        audioPlayer: AudioPlayerService,
        accessibilityPrefix: String,
        density: InAppNowPlayingChrome.PillDensity,
        onExpand: (() -> Void)? = nil,
        onOpen: @escaping () -> Void
    ) {
        self.audioPlayer = audioPlayer
        self.density = density
        self.onExpand = onExpand
        self.onOpen = onOpen
        titleMinWidth = titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: density.titleMinWidth)
        titleMaxWidth = titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: density.titleMaxWidth)
        super.init(frame: .zero)
        accessibilityIdentifier = "\(accessibilityPrefix).pill"
        accessibilityContainerType = .semanticGroup
        let isStripPill = density == .chat

        playPause.accessibilityIdentifier = "\(accessibilityPrefix).playPause"
        playPause.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        loading.translatesAutoresizingMaskIntoConstraints = false
        playPause.addSubview(loading)

        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.isHidden = onExpand == nil
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 7
        titleRow.isUserInteractionEnabled = false
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(chevron)
        titleArea.addSubview(titleRow)
        titleArea.isAccessibilityElement = true
        titleArea.accessibilityTraits = .button
        titleArea.onActivate = { [weak self] in self?.handleTitleTaps(1) }
        if onExpand != nil {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTitleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTitleTap))
            singleTap.require(toFail: doubleTap)
            titleArea.addGestureRecognizer(doubleTap)
            titleArea.addGestureRecognizer(singleTap)
            titleArea.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Open Full Screen")) { [weak self] _ in
                    self?.onOpen()
                    return true
                },
            ]
        } else {
            titleArea.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTitleTap)))
        }

        stop.accessibilityLabel = String(localized: "Stop Playback")
        stop.accessibilityIdentifier = "\(accessibilityPrefix).stop"
        stop.addAction(UIAction { [weak self] _ in self?.audioPlayer.stop() }, for: .touchUpInside)

        stack.axis = .horizontal
        stack.alignment = .center
        // The strip pill's title starts and ends at the 44 pt hit regions.
        stack.spacing = isStripPill ? 0 : 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        [playPause, titleArea, stop].forEach(stack.addArrangedSubview)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.isHidden = !isStripPill
        addSubview(surface)
        addSubview(stack)

        // The strip pill is as tall as its neighbors; its 44 pt hit regions
        // overhang the surface, and `point(inside:)` takes touches there.
        let titleInset = isStripPill ? ExtensionStripPillMetrics.verticalPadding : 0
        let titleFit = titleArea.heightAnchor.constraint(equalTo: titleRow.heightAnchor, constant: 2 * titleInset)
        titleFit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            playPause.widthAnchor.constraint(equalToConstant: density.playPauseHitSize),
            playPause.heightAnchor.constraint(equalToConstant: density.playPauseHitSize),
            stop.widthAnchor.constraint(equalToConstant: density.stopHitSize),
            stop.heightAnchor.constraint(equalToConstant: density.stopHitSize),
            loading.centerXAnchor.constraint(equalTo: playPause.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: playPause.centerYAnchor),
            titleRow.leadingAnchor.constraint(equalTo: titleArea.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: titleArea.trailingAnchor),
            titleRow.centerYAnchor.constraint(equalTo: titleArea.centerYAnchor),
            titleRow.topAnchor.constraint(greaterThanOrEqualTo: titleArea.topAnchor, constant: titleInset),
            titleFit,
            titleMinWidth,
            titleMaxWidth,
        ])
        if isStripPill {
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleArea.heightAnchor.constraint(equalTo: heightAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: density.visualHeight),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The current player, density, and drawer state; also repaints for a
    /// theme change.
    func update(
        audioPlayer: AudioPlayerService,
        density: InAppNowPlayingChrome.PillDensity,
        isExpanded: Bool = false
    ) {
        self.audioPlayer = audioPlayer
        self.density = density
        self.isExpanded = isExpanded
        setNeedsUpdateProperties()
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = ThemeRuntimeState.currentPalette()
        let style = AudioPlayerChromeStyle(palette)
        let action = AudioPlaybackControlAction.resolve(
            isLoading: audioPlayer.loadingItemID != nil && audioPlayer.playingItemID == nil,
            isActive: audioPlayer.playingItemID != nil,
            isPaused: audioPlayer.isPaused
        )
        let title = audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"

        if !surface.isHidden {
            surface.apply(palette: palette, active: isExpanded ? style.foreground : nil)
        }
        loading.apply(style)
        loading.setVisible(action == .cancelLoading)
        playPause.setImage(
            action == .cancelLoading
                ? nil
                : UIImage.scaledSymbol(action == .pause ? "pause.fill" : "play.fill", style: .body, weight: .semibold),
            for: .normal
        )
        playPause.tintColor = style.foreground
        playPause.accessibilityLabel = switch action {
        case .cancelLoading: String(localized: "Cancel Loading")
        case .pause: String(localized: "Pause")
        case .resume, .start: String(localized: "Play")
        }

        titleArea.isHidden = !density.showsTitle
        titleMinWidth.constant = density.titleMinWidth
        titleMaxWidth.constant = density.titleMaxWidth
        titleLabel.text = title
        titleLabel.font = UIFont.scaled(.caption1, .semibold)
        titleLabel.textColor = style.foreground
        chevron.image = UIImage.scaledSymbol(isExpanded ? "chevron.down" : "chevron.right", style: .caption2, weight: .bold)
        chevron.tintColor = style.comment
        titleArea.accessibilityLabel = "Now Playing, \(title)"
        titleArea.accessibilityHint = if onExpand == nil {
            String(localized: "Opens the full-screen audio player")
        } else if isExpanded {
            String(localized: "Collapses the player")
        } else {
            String(localized: "Expands the player")
        }

        stop.setImage(UIImage.scaledSymbol("xmark", style: .body, weight: .semibold), for: .normal)
        stop.tintColor = style.foreground
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let band = max(0, (density.playPauseHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -band).contains(point)
    }

    @objc private func handleTitleTap() { handleTitleTaps(1) }
    @objc private func handleTitleDoubleTap() { handleTitleTaps(2) }

    private func handleTitleTaps(_ tapCount: Int) {
        switch InAppNowPlayingChrome.titleAction(tapCount: tapCount, expandsOnTap: onExpand != nil) {
        case .expandOrCollapse: onExpand?()
        case .openFullScreen: onOpen()
        case nil: break
        }
    }

    private func togglePlayback() {
        switch AudioPlaybackControlAction.resolve(
            isLoading: audioPlayer.loadingItemID != nil && audioPlayer.playingItemID == nil,
            isActive: audioPlayer.playingItemID != nil,
            isPaused: audioPlayer.isPaused
        ) {
        case .cancelLoading: audioPlayer.stop()
        case .pause: audioPlayer.pause()
        case .resume: audioPlayer.resume()
        case .start: break
        }
    }

    /// The title's touch and VoiceOver target: activating it is a tap.
    private final class TitleArea: UIView {
        var onActivate: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            onActivate?()
            return true
        }
    }
}
