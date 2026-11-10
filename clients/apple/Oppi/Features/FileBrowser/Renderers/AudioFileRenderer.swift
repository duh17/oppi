import UIKit

/// A range-streamed audio file in the lyrics player, with timed text beside
/// the file. The file downloads only when the person shares it.
final class AudioFileRenderer: FileRenderer {
    private let source: AuthenticatedMediaSource
    private let file: FileRenderInput
    private var timedText = TimedText.LoadResult.empty {
        didSet { host?.setNeedsUpdateProperties() }
    }
    private var timedTextLoadFinished = false
    private weak var host: FileRendererHost?
    private var player: AudioLyricsPlayerViewController?

    private init(source: AuthenticatedMediaSource, file: FileRenderInput) {
        self.source = source
        self.file = file
    }

    static func load(_ file: FileRenderInput) async throws -> AudioFileRenderer? {
        let source = try await file.access.mediaSource(
            api: file.api,
            path: file.path,
            contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: file.fileExtension),
            sourceFileExtension: file.fileExtension
        )
        guard file.isCurrent() else { return nil }
        return AudioFileRenderer(source: source, file: file)
    }

    var keepsOnReshow: Bool { true }

    func finishLoading() async {
        let result = await file.access.loadTimedText(api: file.api, path: file.path, kind: .audio)
        guard file.isCurrent() else { return }
        timedTextLoadFinished = true
        timedText = result
    }

    func mount(in host: FileRendererHost) -> UIView {
        self.host = host
        let player = AudioLyricsPlayerViewController(configuration: configuration())
        let page = UIView()
        host.addPage(page)
        host.mountChild(player) {
            player.view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(player.view)
            let safe = page.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                player.view.topAnchor.constraint(equalTo: safe.topAnchor),
                player.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                player.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                player.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            ])
        }
        self.player = player
        return page
    }

    /// The lyrics follow what plays: the viewer calls this from `updateProperties()`.
    func update(palette: ThemePalette) {
        player?.apply(configuration())
    }

    private var itemID: String {
        AudioPlaybackItemID.fileBrowser(
            path: file.path,
            workspaceID: file.access.workspaceId,
            sessionID: file.access.sessionId,
            worktreeID: file.access.worktreeId
        )
    }

    /// Reads the player's `@Observable` state.
    private func configuration() -> AudioLyricsPlayerViewController.Configuration {
        let itemID = itemID
        let source = source
        let audioPlayer = file.audioPlayer
        let nowPlayingTimedText = audioPlayer?.nowPlayingTimedText
        let playbackTimedText =
            (audioPlayer?.playingItemID == itemID || audioPlayer?.loadingItemID == itemID)
            && !(nowPlayingTimedText?.tracks.isEmpty ?? true)
            ? (nowPlayingTimedText ?? timedText)
            : timedText
        let playbackTimedTextLoader = timedTextLoadFinished ? nil : file.timedTextLoader(kind: .audio)
        return AudioLyricsPlayerViewController.Configuration(
            title: file.fileName,
            lyrics: nil,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: { selectedTimedText in
                audioPlayer?.toggleMediaPlayback(
                    source: source,
                    itemID: itemID,
                    timedText: selectedTimedText ?? playbackTimedText,
                    timedTextLoader: playbackTimedTextLoader
                )
            },
            openFile: nil,
            shareFileData: nil,
            autoplayOnAppear: false,
            showsCloseButton: false,
            usesNavigationBackButton: false,
            titlePresentation: FileBrowserContentRenderingPolicy.audioPlayerTitlePresentation,
            timedText: playbackTimedText,
            sidecarLoader: nil,
            dismiss: { [weak host] in host?.navigateBack() }
        )
    }

    /// Media stays range-streamed until the person asks to share the file.
    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem? {
        let source = source
        let filename = file.fileName
        let box = Weak<UIBarButtonItem>()
        let item = UIBarButtonItem(
            title: String(localized: "Share"),
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak host] _ in
                guard let button = box.value else { return }
                let token = BarButtonLoadingToken(button: button, tintColor: nil)
                Task { @MainActor in
                    token.start()
                    defer { token.stop() }
                    do {
                        let data = try await source.loadFileData()
                        let item = FileShareService.fileShareItem(data: data, filename: filename)
                        FileSharePresenter.presentActivityController(item: item)
                    } catch is CancellationError {
                        return
                    } catch {
                        host?.errorAlerts.showShareFailure()
                    }
                }
            }
        )
        item.accessibilityIdentifier = "fileBrowser.audio.share"
        box.value = item
        return item
    }
}
