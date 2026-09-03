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
    static let reducedMotionPlayingLevels: [Float] = [0.30, 0.54, 0.76, 1, 0.72, 0.48, 0.28]
    private static let waveformPhaseOffsets: [Double] = [0, 1.7, 3.6, 5.1, 2.7, 4.4, 0.9]
    private static let waveformSpeeds: [Double] = [1, 1.25, 0.85, 1.4, 0.95, 1.18, 0.78]

    static func displayedWaveformLevels(
        snapshot: [Float],
        isPlaying: Bool,
        reduceMotion: Bool,
        elapsed: TimeInterval = 0
    ) -> [Float] {
        guard isPlaying else {
            return Array(
                repeating: AudioPlayerService.restingWaveformLevel,
                count: AudioPlayerService.waveformBarCount
            )
        }
        if reduceMotion {
            return reducedMotionPlayingLevels
        }

        let meterSnapshot = snapshot.count == AudioPlayerService.waveformBarCount
            ? snapshot
            : AudioPlayerService.waveformLevels(fromMeterLevel: 0, isPlaying: true)
        return meterSnapshot.enumerated().map { index, rawLevel in
            let sourceLevel = min(1, max(0, rawLevel.isFinite ? rawLevel : 0))
            let phase = elapsed * 5.2 * waveformSpeeds[index] + waveformPhaseOffsets[index]
            let oscillator = Float((sin(phase) + 1) / 2)
            let ceiling = 0.58 + 0.42 * sourceLevel
            let pulse = 0.08 + 0.92 * oscillator
            return AudioPlayerService.restingWaveformLevel
                + (ceiling - AudioPlayerService.restingWaveformLevel) * pulse
        }
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
                        if density.showsWaveform {
                            InAppNowPlayingWaveform(
                                levels: audioPlayer.waveformLevels,
                                isPlaying: isActivelyPlaying,
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now Playing, \(title)")
                .accessibilityHint("Opens the full-screen audio player")
            }
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
        TimelineView(
            .animation(
                minimumInterval: 1 / 15,
                paused: !isPlaying || reduceMotion
            )
        ) { context in
            let displayedLevels = InAppNowPlayingChrome.displayedWaveformLevels(
                snapshot: levels,
                isPlaying: isPlaying,
                reduceMotion: reduceMotion,
                elapsed: context.date.timeIntervalSinceReferenceDate
            )
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(displayedLevels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(isPlaying ? Color.themeFg : Color.themeComment)
                        .frame(width: 2.5, height: 22)
                        .scaleEffect(x: 1, y: barScale(level), anchor: .center)
                }
            }
            .frame(width: 28, height: 24)
        }
        .accessibilityHidden(true)
    }

    private func barScale(_ level: Float) -> CGFloat {
        let minScale: CGFloat = 4 / 22
        let clamped = CGFloat(min(1, max(0, level)))
        return minScale + clamped * (1 - minScale)
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
