import UIKit

/// Whether the player draws its own title in its header.
///
/// Embedded surfaces (the file browser) already show the filename in the host
/// navigation bar, so the player must not repeat it. Modal, timeline, and
/// full-screen Now Playing surfaces own their header and draw the title once.
/// This is an explicit presentation choice, independent of `showsCloseButton`.
enum AudioLyricsPlayerTitlePresentation: Equatable {
    case playerShowsTitle
    case hostOwnsTitle

    var showsInternalTitle: Bool {
        switch self {
        case .playerShowsTitle: return true
        case .hostOwnsTitle: return false
        }
    }
}

enum AudioLyricsPlayerPresenter {
    @MainActor
    static func shouldAutoplayOnAppear(
        itemID: String,
        audioPlayer: AudioPlayerService?,
        playNow: Bool
    ) -> Bool {
        if playNow { return true }
        guard let audioPlayer else { return false }
        return audioPlayer.playingItemID == itemID
            || audioPlayer.isStreamingPlaybackActive(itemID: itemID)
    }

    @MainActor
    static func present(
        from view: UIView,
        title: String,
        lyrics: String?,
        itemID: String,
        audioPlayer: AudioPlayerService?,
        play: @escaping (TimedText.LoadResult?) -> Void,
        openFile: (() -> Void)?,
        shareFileData: (() async throws -> Data)? = nil,
        autoplayOnAppear: Bool,
        timedText: TimedText.LoadResult? = nil,
        sidecarLoader: (() async -> TimedText.LoadResult)? = nil
    ) {
        // Expand starts playback only when the caller opts in: already playing
        // this item, or a voice `playNow` reply. Markdown and file browser pass false.
        guard let presenter = nearestViewController(from: view) else { return }
        if ChatReaderOpenLookup.open(
            .audioLyrics(
                AudioLyricsReaderContent(
                    title: title,
                    lyrics: lyrics,
                    itemID: itemID,
                    audioPlayer: audioPlayer,
                    play: play,
                    openFile: openFile,
                    shareFileData: shareFileData,
                    autoplayOnAppear: autoplayOnAppear,
                    timedText: timedText,
                    sidecarLoader: sidecarLoader
                )
            ),
            from: view
        ) {
            return
        }
        let player = AudioLyricsPlayerViewController(configuration: .init(
            title: title,
            lyrics: lyrics,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: play,
            openFile: openFile,
            shareFileData: shareFileData,
            autoplayOnAppear: autoplayOnAppear,
            showsCloseButton: true,
            timedText: timedText,
            sidecarLoader: sidecarLoader
        ))
        player.modalPresentationStyle = .fullScreen
        presenter.present(player, animated: true)
    }

    @MainActor
    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

enum AudioPlaybackControlAction: Equatable {
    case start
    case cancelLoading
    case pause
    case resume

    static func resolve(
        isLoading: Bool,
        isActive: Bool,
        isPaused: Bool
    ) -> Self {
        if isLoading { return .cancelLoading }
        guard isActive else { return .start }
        return isPaused ? .resume : .pause
    }
}

enum AudioPlaybackTransportDensity {
    case fullScreen
    case drawer

    var stackSpacing: CGFloat { self == .fullScreen ? 16 : 10 }
    var controlSpacing: CGFloat { self == .fullScreen ? 28 : 24 }
    var playSize: CGFloat { self == .fullScreen ? 56 : 44 }
    var playSymbolSize: CGFloat { self == .fullScreen ? 36 : 24 }
    var horizontalPadding: CGFloat { self == .fullScreen ? 24 : 0 }
    var bottomPadding: CGFloat { self == .fullScreen ? 28 : 0 }
    var topPadding: CGFloat { self == .fullScreen ? 8 : 0 }
}
