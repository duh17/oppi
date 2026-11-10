import UIKit

/// A range-streamed video in the app's player, with captions beside the file.
final class VideoFileRenderer: FileRenderer {
    private let source: AuthenticatedMediaSource
    private let timedTextLoader: () async -> TimedText.LoadResult
    private var model: AuthenticatedMediaPlayerModel?
    private var player: AuthenticatedMediaPlayerHostController?
    private var page: AspectFitMediaView?

    private init(source: AuthenticatedMediaSource, timedTextLoader: @escaping () async -> TimedText.LoadResult) {
        self.source = source
        self.timedTextLoader = timedTextLoader
    }

    static func load(_ file: FileRenderInput) async throws -> VideoFileRenderer? {
        let source = try await file.access.mediaSource(
            api: file.api,
            path: file.path,
            contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: file.fileExtension),
            sourceFileExtension: file.fileExtension
        )
        guard file.isCurrent() else { return nil }
        return VideoFileRenderer(source: source, timedTextLoader: file.timedTextLoader(kind: .video))
    }

    var retention: FileRendererRetention { .keepOnReshow }

    func mount(in host: FileRendererHost) -> UIView {
        let model = AuthenticatedMediaPlayerModel()
        let player = AuthenticatedMediaPlayerHostController(model: model)
        // The host runs the loader once per source and attaches captions to
        // the player overlay, even during fullscreen.
        player.update(
            model: model,
            sourceIdentity: source.identity,
            chrome: AuthenticatedMediaPlayerHostController.Chrome(
                unavailableTitle: "Video preview unavailable",
                unavailableSystemImage: "film.slash"
            ),
            timedTextLoader: timedTextLoader
        )
        // The player takes the video's own proportions inside the page; until
        // its size arrives (`prepare`) the box is 16:9.
        let page = host.mountChild(player) {
            player.view.layer.cornerRadius = 10
            player.view.clipsToBounds = true
            let page = AspectFitMediaView(content: player.view)
            host.addPage(page)
            return page
        }
        self.model = model
        self.player = player
        self.page = page
        if host.isOnScreen {
            prepare(model)
        }
        return page
    }

    private func prepare(_ model: AuthenticatedMediaPlayerModel) {
        model.setVisible(true)
        model.prepare(
            source: source,
            autoplay: false,
            telemetrySource: "authenticated_media",
            telemetryMode: "inline",
            telemetrySessionId: nil,
            onPresentationSize: { [weak self] size in self?.page?.contentSize = size }
        )
    }

    func updateMounted(palette: ThemePalette) {
        page?.backgroundColor = palette.ui.bgDark
    }

    func viewerDidAppear() {
        if let model { prepare(model) }
    }

    func viewerDidDisappear() {
        model?.handleDisappear()
    }

    func release() {
        guard let model else { return }
        model.handleDisappear()
        player?.dispose()
    }
}
