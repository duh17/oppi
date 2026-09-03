import SwiftUI
import UIKit

enum InAppNowPlayingChrome {
    enum SessionListToolbar: Equatable {
        case searchField
        case collapsedSearchWithNowPlaying
    }

    enum PillDensity: Equatable {
        case chat
        case sessionList

        var showsTitle: Bool {
            self == .chat
        }

        /// Waveform replaces the subtitle so the compact pill does not crowd.
        var showsSubtitle: Bool {
            false
        }

        var titleMaxWidth: CGFloat {
            switch self {
            case .chat: return 180
            case .sessionList: return 120
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

    static func sessionListToolbar(hasActivePlayback: Bool) -> SessionListToolbar {
        hasActivePlayback ? .collapsedSearchWithNowPlaying : .searchField
    }

    /// Reduce Motion keeps bars static. Playing motion is an extra cue, not the only one.
    static let reducedMotionPlayingLevels: [Float] = [0.28, 0.46, 0.58, 0.40, 0.32]

    static func displayedWaveformLevels(
        snapshot: [Float],
        isPlaying: Bool,
        reduceMotion: Bool
    ) -> [Float] {
        if reduceMotion {
            return isPlaying
                ? reducedMotionPlayingLevels
                : Array(
                    repeating: AudioPlayerService.restingWaveformLevel,
                    count: AudioPlayerService.waveformBarCount
                )
        }
        if !isPlaying {
            return Array(
                repeating: AudioPlayerService.restingWaveformLevel,
                count: AudioPlayerService.waveformBarCount
            )
        }
        if snapshot.count == AudioPlayerService.waveformBarCount {
            return snapshot
        }
        return AudioPlayerService.waveformLevels(fromMeterLevel: 0, isPlaying: true)
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

    private var waveformLevels: [Float] {
        InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: audioPlayer.waveformLevels,
            isPlaying: isActivelyPlaying,
            reduceMotion: reduceMotion
        )
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

            Button(action: onOpen) {
                HStack(spacing: 6) {
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
                    InAppNowPlayingWaveform(
                        levels: waveformLevels,
                        isPlaying: isActivelyPlaying,
                        reduceMotion: reduceMotion
                    )
                }
                .frame(
                    minWidth: density.showsTitle ? nil : density.playPauseHitSize,
                    minHeight: density.playPauseHitSize,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing, \(title)")
            .accessibilityHint("Opens the full-screen audio player")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).pill")
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
    var reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(isPlaying ? Color.themeFg : Color.themeComment)
                    .frame(width: 3, height: 16)
                    .scaleEffect(x: 1, y: barScale(level), anchor: .center)
            }
        }
        .frame(width: 22, height: 18)
        .animation(
            ThemeMotion.easeInOut(duration: 0.12, reduceMotion: reduceMotion),
            value: levels
        )
        .accessibilityHidden(true)
    }

    private func barScale(_ level: Float) -> CGFloat {
        let minScale: CGFloat = 4 / 16
        let clamped = CGFloat(min(1, max(0, level)))
        return minScale + clamped * (1 - minScale)
    }
}

struct InAppNowPlayingSearchIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.themeFg)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search sessions")
        .accessibilityIdentifier("sessionList.nowPlaying.search")
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
