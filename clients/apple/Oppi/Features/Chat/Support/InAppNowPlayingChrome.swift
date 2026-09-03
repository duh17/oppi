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

        var pillShowsWaveform: Bool {
            self == .minimizedSearchWithNowPlaying
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
            self == .chat
        }

        /// Waveform replaces the subtitle so the compact pill does not crowd.
        var showsSubtitle: Bool {
            false
        }

        var showsWaveform: Bool {
            self != .sessionListCompact
        }

        var titleMaxWidth: CGFloat {
            switch self {
            case .chat: return 180
            case .sessionList, .sessionListCompact: return 120
            }
        }

        var playPauseHitSize: CGFloat { 44 }
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

    /// Reduce Motion keeps a recognizable waveform silhouette without periodic updates.
    static let reducedMotionPlayingLevels = AudioPlayerService.placeholderWaveformLevels

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

    static func displayedWaveformLevels(
        snapshot: [Float],
        isPlaying: Bool,
        isPaused: Bool,
        reduceMotion: Bool
    ) -> [Float] {
        if !isPlaying && !isPaused {
            return Array(
                repeating: AudioPlayerService.restingWaveformLevel,
                count: AudioPlayerService.waveformBarCount
            )
        }
        if reduceMotion && isPlaying {
            return reducedMotionPlayingLevels
        }
        if snapshot.count == AudioPlayerService.waveformBarCount {
            return snapshot.map { level in
                min(1, max(0, level.isFinite ? level : 0))
            }
        }
        return reducedMotionPlayingLevels
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

struct InAppNowPlayingPill: View {
    @Bindable var audioPlayer: AudioPlayerService
    var accessibilityPrefix: String
    var density: InAppNowPlayingChrome.PillDensity = .chat
    var isExpanded = false
    var onExpand: (() -> Void)? = nil
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: AudioPlayerService.NowPlayingPresentation? {
        audioPlayer.nowPlayingPresentation
    }

    private var title: String {
        presentation?.title ?? "Now Playing"
    }

    private var subtitle: String? {
        guard let subtitle = presentation?.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else {
            return nil
        }
        return subtitle
    }

    private var isActivelyPlaying: Bool {
        audioPlayer.playingItemID != nil && !audioPlayer.isPaused
    }

    private var expandsOnTap: Bool {
        onExpand != nil
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: togglePlayback) {
                Image(systemName: isActivelyPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .frame(width: density.playPauseHitSize, height: density.playPauseHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActivelyPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("\(accessibilityPrefix).playPause")

            if density.showsTitle || density.showsWaveform {
                titleAndWaveform
            }
        }
        .padding(.horizontal, density == .chat ? 10 : 0)
        .padding(.vertical, density == .chat ? 4 : 0)
        .background {
            if density == .chat {
                Capsule()
                    .fill(.themeFg.opacity(isExpanded ? 0.1 : 0.045))
            }
        }
        .overlay {
            if density == .chat {
                Capsule()
                    .stroke(isExpanded ? Color.themeFg.opacity(0.45) : Color.themeFg.opacity(0.08), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).pill")
    }

    @ViewBuilder
    private var titleAndWaveform: some View {
        let content = HStack(spacing: 6) {
            if density.showsTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if density.showsSubtitle, let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: density.titleMaxWidth, alignment: .leading)
            }
            if density.showsWaveform {
                InAppNowPlayingWaveform(
                    levels: audioPlayer.waveformLevels,
                    isPlaying: isActivelyPlaying,
                    isPaused: audioPlayer.isPaused,
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(
            minWidth: density.showsTitle ? nil : density.playPauseHitSize,
            minHeight: density.playPauseHitSize,
            alignment: .leading
        )
        .contentShape(Rectangle())

        if expandsOnTap {
            content
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
        } else {
            Button(action: onOpen) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing, \(title)")
            .accessibilityHint("Opens the full-screen audio player")
        }
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
        guard audioPlayer.playingItemID != nil else { return }
        if audioPlayer.isPaused {
            audioPlayer.resume()
        } else {
            audioPlayer.pause()
        }
    }
}

struct InAppNowPlayingWaveform: View {
    var levels: [Float]
    var isPlaying: Bool
    var isPaused: Bool = false
    var reduceMotion: Bool
    var barHeight: CGFloat = 22
    var barWidth: CGFloat = 2.5

    var body: some View {
        let displayedLevels = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: levels,
            isPlaying: isPlaying,
            isPaused: isPaused,
            reduceMotion: reduceMotion
        )
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(displayedLevels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill((isPlaying || isPaused) ? Color.themeFg : Color.themeComment)
                    .frame(width: barWidth, height: barHeight)
                    .scaleEffect(x: 1, y: barScale(level), anchor: .center)
            }
        }
        .frame(height: max(24, barHeight))
        .accessibilityHidden(true)
    }

    private func barScale(_ level: Float) -> CGFloat {
        let minScale: CGFloat = 4 / max(barHeight, 1)
        let clamped = CGFloat(min(1, max(0, level)))
        return minScale + clamped * (1 - minScale)
    }
}

struct InAppNowPlayingDrawer: View {
    @Bindable var audioPlayer: AudioPlayerService
    var accessibilityPrefix: String
    let onCollapse: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"
    }

    private var isActivelyPlaying: Bool {
        audioPlayer.playingItemID != nil && !audioPlayer.isPaused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 32, height: 32)
                        .background(.themeFg.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).drawer.collapse")
                .accessibilityLabel("Collapse Now Playing")
            }

            InAppNowPlayingWaveform(
                levels: audioPlayer.waveformLevels,
                isPlaying: isActivelyPlaying,
                isPaused: audioPlayer.isPaused,
                reduceMotion: reduceMotion,
                barHeight: 36,
                barWidth: 3
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 2)
        .accessibilityIdentifier("\(accessibilityPrefix).drawer")
    }

    private var timeLabel: String {
        AudioPlaybackTimeFormatting.elapsedDuration(
            elapsed: audioPlayer.currentTime,
            duration: audioPlayer.duration
        )
    }
}

struct InAppNowPlayingPlayerScreen: View {
    let audioPlayer: AudioPlayerService

    var body: some View {
        AudioLyricsPlayerView(
            title: audioPlayer.nowPlayingPresentation?.title ?? "Now Playing",
            lyrics: nil,
            itemID: audioPlayer.playingItemID ?? audioPlayer.loadingItemID ?? "",
            audioPlayer: audioPlayer,
            play: {
                if audioPlayer.isPaused {
                    audioPlayer.resume()
                }
            },
            openFile: nil,
            autoplayOnAppear: false
        )
    }
}
