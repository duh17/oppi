import SwiftUI
import UIKit

enum InAppNowPlayingChrome {
    enum SessionListToolbar: Equatable {
        case searchField
        case minimizedSearchWithNowPlaying
        case expandedSearchWithCompactNowPlaying

        /// iOS search only expands from the system search toolbar item.
        var keepsSystemSearchToolbarItem: Bool { true }

        var usesMinimizedSearch: Bool {
            self != .searchField
        }

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
    static let streamPlaybackPrefix = "stream:"

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
        if playbackItemID == streamPlaybackPrefix + stripItemID { return true }
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
        Button(action: { audioPlayer.stop() }) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.themeFg)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
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

struct InAppNowPlayingDrawer: View {
    @Bindable var audioPlayer: AudioPlayerService
    var accessibilityPrefix: String
    let onCollapse: () -> Void
    let onOpen: () -> Void

    private var itemID: String {
        audioPlayer.playingItemID ?? audioPlayer.loadingItemID ?? ""
    }

    private var title: String {
        audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"
    }

    private var subtitlePresentation: InAppNowPlayingChrome.SubtitlePresentation {
        InAppNowPlayingChrome.subtitlePresentation(
            in: audioPlayer.nowPlayingTimedText,
            at: audioPlayer.currentTime,
            isLoading: audioPlayer.isNowPlayingTimedTextLoading
        )
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch subtitlePresentation {
        case .cue(let text):
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(.themeFg)
                .lineLimit(2)
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading lyrics…")
            }
            .font(.callout)
            .foregroundStyle(.themeComment)
        case .gap:
            Text("…")
                .font(.body.weight(.medium))
                .foregroundStyle(.themeComment)
                .accessibilityLabel("No lyric at the current position")
        case .unavailable:
            Text("No lyrics")
                .font(.callout)
                .foregroundStyle(.themeComment)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    subtitleView
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Double tap to open the full-screen audio player")
                .accessibilityAction(named: Text("Open Full Screen"), onOpen)
                .onTapGesture(count: 2, perform: onOpen)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 44, height: 44)
                        .background(.themeFg.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).drawer.collapse")
                .accessibilityLabel("Collapse Now Playing")

                InAppNowPlayingStopButton(
                    audioPlayer: audioPlayer,
                    accessibilityIdentifier: "\(accessibilityPrefix).drawer.stop"
                )
            }

            AudioPlaybackTransportControls(
                itemID: itemID,
                audioPlayer: audioPlayer,
                play: {
                    if audioPlayer.isPaused {
                        audioPlayer.resume()
                    }
                },
                density: .drawer,
                accessibilityPrefix: "\(accessibilityPrefix).drawer"
            )
        }
        .padding(12)
        .extensionGlassPanel(cornerRadius: 18)
        .accessibilityIdentifier("\(accessibilityPrefix).drawer")
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
