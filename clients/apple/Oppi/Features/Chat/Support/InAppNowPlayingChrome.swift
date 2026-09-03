import SwiftUI
import UIKit

enum InAppNowPlayingChrome {
    enum SessionListToolbar: Equatable {
        case searchField
        case collapsedSearchWithNowPlaying
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

    static func matchesPlayback(_ playbackItemID: String, stripItemID: String) -> Bool {
        if playbackItemID == stripItemID { return true }
        if playbackItemID == directSpeakPlaybackPrefix + stripItemID { return true }
        if playbackItemID == streamPlaybackPrefix + stripItemID { return true }
        return false
    }

    @MainActor
    static func visibleStripItemIDs(in root: UIView, unobstructedRect: CGRect) -> Set<String> {
        var ids = Set<String>()
        collectStripItemIDs(from: root, root: root, unobstructedRect: unobstructedRect, into: &ids)
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
    let onOpen: () -> Void

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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActivelyPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("\(accessibilityPrefix).playPause")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: 180, minHeight: 44, alignment: .leading)
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
