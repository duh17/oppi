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

struct InAppNowPlayingStopButton: View {
    let audioPlayer: AudioPlayerService
    var accessibilityIdentifier: String
    var size: CGFloat = 44

    var body: some View {
        Button(action: { audioPlayer.stop() }, label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.themeFg)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel("Stop Playback")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct InAppNowPlayingPill: View {
    @Bindable var audioPlayer: AudioPlayerService
    var accessibilityPrefix: String
    var density: InAppNowPlayingChrome.PillDensity = .chat
    var isExpanded = false
    var onExpand: (() -> Void)? = nil
    let onOpen: () -> Void

    private var title: String {
        audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"
    }

    private var controlAction: AudioPlaybackControlAction {
        AudioPlaybackControlAction.resolve(
            isLoading: audioPlayer.loadingItemID != nil && audioPlayer.playingItemID == nil,
            isActive: audioPlayer.playingItemID != nil,
            isPaused: audioPlayer.isPaused
        )
    }

    private var expandsOnTap: Bool {
        onExpand != nil
    }

    @ViewBuilder
    var body: some View {
        if density == .chat {
            chatPill
        } else {
            toolbarPill
        }
    }

    private var chatPill: some View {
        HStack(spacing: 7) {
            // Reserve the 44pt play/pause hit region without making the visible
            // capsule taller than neighboring extension pills.
            Color.clear
                .frame(
                    width: density.playPauseHitSize
                        - ExtensionStripPillMetrics.horizontalPadding
                        - 7,
                    height: 20
                )
                .accessibilityHidden(true)
            titleContent
                .accessibilityHidden(true)
            Color.clear
                .frame(
                    width: density.stopHitSize
                        - ExtensionStripPillMetrics.horizontalPadding
                        - 7,
                    height: 20
                )
                .accessibilityHidden(true)
        }
        .extensionStripPillSurface(isActive: isExpanded, activeStroke: .themeFg)
        .frame(minHeight: density.visualHeight)
        .overlay(alignment: .leading) {
            playPauseButton
        }
        .overlay {
            chatTitleHitTarget
        }
        .overlay(alignment: .trailing) {
            stopButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).pill")
    }

    private var toolbarPill: some View {
        HStack(spacing: 4) {
            playPauseButton
            if density.showsTitle {
                toolbarTitleButton
            }
            stopButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).pill")
    }

    private var playPauseButton: some View {
        Button(action: togglePlayback) {
            if controlAction == .cancelLoading {
                AudioLoadingCancelControl(size: density.playPauseHitSize)
            } else {
                Image(systemName: controlAction == .pause ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .frame(width: density.playPauseHitSize, height: density.playPauseHitSize)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controlAccessibilityLabel)
        .accessibilityIdentifier("\(accessibilityPrefix).playPause")
    }

    private var controlAccessibilityLabel: String {
        switch controlAction {
        case .cancelLoading: return "Cancel Loading"
        case .pause: return "Pause"
        case .resume, .start: return "Play"
        }
    }

    private var titleContent: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    minWidth: density.titleMinWidth,
                    maxWidth: density.titleMaxWidth,
                    alignment: .leading
                )
                .layoutPriority(1)

            if expandsOnTap {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
        }
    }

    private var toolbarTitleButton: some View {
        Button(action: onOpen) {
            titleContent
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Now Playing, \(title)")
        .accessibilityHint("Opens the full-screen audio player")
    }

    private var chatTitleHitTarget: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: density.playPauseHitSize)
                .allowsHitTesting(false)
            Color.clear
                .frame(maxWidth: .infinity, minHeight: density.playPauseHitSize)
                .contentShape(Rectangle())
                .accessibilityLabel("Now Playing, \(title)")
                .accessibilityHint(isExpanded ? "Collapses the player" : "Expands the player")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Open Full Screen"), onOpen)
                .gesture(
                    TapGesture(count: 2).onEnded {
                        handleTitleTaps(2)
                    }
                    .exclusively(before: TapGesture(count: 1).onEnded {
                        handleTitleTaps(1)
                    })
                )
            Color.clear
                .frame(width: density.stopHitSize)
                .allowsHitTesting(false)
        }
    }

    private var stopButton: some View {
        InAppNowPlayingStopButton(
            audioPlayer: audioPlayer,
            accessibilityIdentifier: "\(accessibilityPrefix).stop",
            size: density.stopHitSize
        )
    }

    private func handleTitleTaps(_ tapCount: Int) {
        switch InAppNowPlayingChrome.titleAction(tapCount: tapCount, expandsOnTap: expandsOnTap) {
        case .expandOrCollapse:
            onExpand?()
        case .openFullScreen:
            onOpen()
        case nil:
            break
        }
    }

    private func togglePlayback() {
        switch controlAction {
        case .cancelLoading:
            audioPlayer.stop()
        case .pause:
            audioPlayer.pause()
        case .resume:
            audioPlayer.resume()
        case .start:
            break
        }
    }
}

private extension View {
    /// The strip pill's padding, height, and surface, as the UIKit strip pills
    /// draw it (`ExtensionStripPillControl`).
    func extensionStripPillSurface(isActive: Bool, activeStroke: Color) -> some View {
        self
            .padding(.horizontal, ExtensionStripPillMetrics.horizontalPadding)
            .padding(.vertical, ExtensionStripPillMetrics.verticalPadding)
            .frame(minHeight: ExtensionStripPillMetrics.visualHeight)
            .themedSurface(.elevatedPanel, in: Capsule())
            .overlay {
                if isActive {
                    Capsule()
                        .stroke(activeStroke.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
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

/// The session lists' now-playing pill in the bottom bar: play/pause (a
/// cancel spinner while loading), the title that opens the full-screen
/// player, and stop. Reads `AudioPlayerService` in `updateProperties()`, so
/// it follows playback on its own. The chat footer still draws the SwiftUI
/// `InAppNowPlayingPill` (`.chat` density, expand on tap).
final class InAppNowPlayingPillView: UIView {
    private var audioPlayer: AudioPlayerService
    private let accessibilityPrefix: String
    private let onOpen: () -> Void
    private var density: InAppNowPlayingChrome.PillDensity

    private let stack = UIStackView()
    private let playPause = UIButton(type: .custom)
    private let loading = AudioLoadingCancelView(style: AudioPlayerChromeStyle())
    private let titleButton = UIButton(type: .custom)
    private let titleWidth: NSLayoutConstraint
    private let stop = UIButton(type: .custom)

    init(
        audioPlayer: AudioPlayerService,
        accessibilityPrefix: String,
        density: InAppNowPlayingChrome.PillDensity,
        onOpen: @escaping () -> Void
    ) {
        self.audioPlayer = audioPlayer
        self.accessibilityPrefix = accessibilityPrefix
        self.density = density
        self.onOpen = onOpen
        titleWidth = titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: density.titleMaxWidth)
        super.init(frame: .zero)
        accessibilityIdentifier = "\(accessibilityPrefix).pill"
        accessibilityContainerType = .semanticGroup

        playPause.accessibilityIdentifier = "\(accessibilityPrefix).playPause"
        playPause.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        loading.translatesAutoresizingMaskIntoConstraints = false
        playPause.addSubview(loading)

        titleButton.contentHorizontalAlignment = .leading
        titleButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        titleButton.accessibilityHint = String(localized: "Opens the full-screen audio player")
        titleButton.addAction(UIAction { [weak self] _ in self?.onOpen() }, for: .touchUpInside)
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stop.accessibilityLabel = String(localized: "Stop Playback")
        stop.accessibilityIdentifier = "\(accessibilityPrefix).stop"
        stop.addAction(UIAction { [weak self] _ in self?.audioPlayer.stop() }, for: .touchUpInside)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        [playPause, titleButton, stop].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            playPause.widthAnchor.constraint(equalToConstant: density.playPauseHitSize),
            playPause.heightAnchor.constraint(equalToConstant: density.playPauseHitSize),
            stop.widthAnchor.constraint(equalToConstant: density.stopHitSize),
            stop.heightAnchor.constraint(equalToConstant: density.stopHitSize),
            loading.centerXAnchor.constraint(equalTo: playPause.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: playPause.centerYAnchor),
            titleWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The list's current player and density; also repaints for a theme change.
    func update(audioPlayer: AudioPlayerService, density: InAppNowPlayingChrome.PillDensity) {
        self.audioPlayer = audioPlayer
        self.density = density
        setNeedsUpdateProperties()
    }

    override func updateProperties() {
        super.updateProperties()
        let style = AudioPlayerChromeStyle()
        let action = AudioPlaybackControlAction.resolve(
            isLoading: audioPlayer.loadingItemID != nil && audioPlayer.playingItemID == nil,
            isActive: audioPlayer.playingItemID != nil,
            isPaused: audioPlayer.isPaused
        )
        let title = audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"

        loading.apply(style)
        loading.setVisible(action == .cancelLoading)
        playPause.setImage(
            action == .cancelLoading
                ? nil
                : AudioPlayerChromeStyle.symbol(action == .pause ? "pause.fill" : "play.fill", style: .body, weight: .semibold),
            for: .normal
        )
        playPause.tintColor = style.foreground
        playPause.accessibilityLabel = switch action {
        case .cancelLoading: String(localized: "Cancel Loading")
        case .pause: String(localized: "Pause")
        case .resume, .start: String(localized: "Play")
        }

        titleButton.isHidden = !density.showsTitle
        titleWidth.constant = density.titleMaxWidth
        titleButton.setAttributedTitle(NSAttributedString(string: title, attributes: [
            .font: AudioPlayerChromeStyle.font(.caption1, weight: .semibold),
            .foregroundColor: style.foreground,
        ]), for: .normal)
        titleButton.accessibilityLabel = "Now Playing, \(title)"

        stop.setImage(AudioPlayerChromeStyle.symbol("xmark", style: .body, weight: .semibold), for: .normal)
        stop.tintColor = style.foreground
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
}
