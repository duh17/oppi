import UIKit

/// Shows one preview category in the file viewer (`FileViewerViewController`).
///
/// The viewer picks the renderer for a file's `FileKind.previewCategory`
/// through `FileRendererRegistry`, calls `load`, keeps the result as its
/// rendered-file state, and `mount`s it. Text is not a renderer: the viewer's
/// reader and editor share the file's edit owner.
///
/// A renderer instance lives as long as the viewer shows its file. Everything
/// but `load`, `mount`, and `share` has a default; a renderer implements only
/// the hooks it needs.
@MainActor
protocol FileRenderer: AnyObject {
    /// Reads `file` and holds what `mount` shows. Nil when the viewer moved to
    /// another file meanwhile.
    static func load(_ file: FileRenderInput) async throws -> Self?
    /// The page for the loaded file, added to `host`'s page.
    func mount(in host: FileRendererHost) -> UIView
    /// What the bar's Share sends: the real file, from the bytes the renderer
    /// holds or downloaded when asked. No default, so no kind goes without.
    var share: ShareableFile { get }

    /// The page handles a horizontal back swipe itself (paging, 3D drag).
    var ownsBackSwipe: Bool { get }
    var retention: FileRendererRetention { get }
    /// Runs in the load after the page shows: reads that can follow it.
    func finishLoading() async
    /// Called on every viewer update while mounted: theme colors and observed
    /// player state.
    func updateMounted(palette: ThemePalette)
    func viewerDidAppear()
    func viewerDidDisappear()
    /// The viewer stopped showing this renderer: free what it holds.
    func release()
}

extension FileRenderer {
    var ownsBackSwipe: Bool { false }
    var retention: FileRendererRetention { .reloadOnReshow }
    func finishLoading() async {}
    func updateMounted(palette: ThemePalette) {}
    func viewerDidAppear() {}
    func viewerDidDisappear() {}
    func release() {}
}

/// What the viewer does with a renderer when its file shows again (a
/// full-screen modal over it, a resize) or the viewer leaves the screen.
enum FileRendererRetention {
    /// Read the file again on every re-show.
    case reloadOnReshow
    /// Keep this renderer and its player when the same file shows again.
    case keepOnReshow
    /// Drop this renderer when the viewer leaves the screen; read the file
    /// again when it comes back.
    case releaseOffScreen
}

/// The renderer for each preview category the viewer does not show as text.
/// Adding a format: a `FileKindTable` row for its extensions, and a category
/// here with its renderer when no existing one draws it.
enum FileRendererRegistry {
    static func renderer(for category: FilePreviewCategory) -> (any FileRenderer.Type)? {
        switch category {
        case .image: ImageFileRenderer.self
        case .audio: AudioFileRenderer.self
        case .video: VideoFileRenderer.self
        case .pdf: PDFFileRenderer.self
        case .usdz: USDZFileRenderer.self
        case .book: BookFileRenderer.self
        case .binary: BinaryFileRenderer.self
        case .text: nil
        }
    }
}

/// The file a renderer reads, where it lives, and what it reads with.
@MainActor
struct FileRenderInput {
    let api: APIClient
    let access: FileViewerFileAccess
    let path: String
    let fileName: String
    let audioPlayer: AudioPlayerService?
    /// Bytes the viewer already read (text that did not decode); `bytes()` returns them.
    let preread: Data?
    /// False once the viewer shows another file or the load was cancelled.
    let isCurrent: @MainActor () -> Bool

    var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    /// The file's bytes and, for a host file, the path it resolved to. Nil
    /// when the viewer moved to another file meanwhile.
    func bytes() async throws -> (data: Data, resolvedHostPath: String?)? {
        if let preread { return (preread, nil) }
        if access.source == .hostFile {
            let file = try await api.browseHostFileContent(path: path, controlSessionId: access.controlSessionId)
            guard isCurrent() else { return nil }
            return (file.data, file.resolvedPath)
        }
        let data = try await access.browseFile(api: api, path: path)
        guard isCurrent() else { return nil }
        return (data, nil)
    }

    /// This file as Share downloads it, for a renderer that streams it.
    var remoteShare: RemoteFileShare {
        access.remoteFileShare(api: api, path: path, fileName: fileName, size: nil)
    }

    /// Captions or lyrics beside this media file, read when the player asks.
    func timedTextLoader(kind: TimedText.MediaKind) -> () async -> TimedText.LoadResult {
        let (api, access, path) = (api, access, path)
        return { await access.loadTimedText(api: api, path: path, kind: kind) }
    }
}

/// What a renderer mounts into: the file viewer's page and its navigation.
@MainActor
protocol FileRendererHost: UIViewController {
    var isOnScreen: Bool { get }
    /// Adds a full-page container to the viewer's page.
    func addPage(_ page: UIView)
    /// Adds `controller` as a child the viewer removes on the next mount;
    /// `attach` puts its view in place between `addChild` and `didMove`.
    func mountChild<Attached>(_ controller: UIViewController, attach: () -> Attached) -> Attached
    /// A full page with the unavailable or failed state.
    func unavailable(_ state: LoadState) -> UIView
    /// A state view the viewer repaints on a theme change, for the caller to place.
    func makeStateView(_ state: LoadState) -> UIContentUnavailableView
    func removeStateView()
    /// For a page that keeps the back swipe (`ownsBackSwipe`) but shows a
    /// view without its own gesture.
    func installOwnBackSwipe(on view: UIView)
    /// The reader page for content the viewer does not edit.
    func mountReader(_ content: FullScreenCodeContent) -> UIView
    func navigateBack()
}

extension ShareableFile {
    /// The viewer's titled Share item, for `screen`'s bar.
    @MainActor func barItem(from screen: UIViewController) -> UIBarButtonItem {
        let item = FileSharePresenter.makeShareBarButtonItem(for: self, from: screen)
        item.title = String(localized: "Share")
        item.accessibilityIdentifier = "fileViewer.share"
        return item
    }
}
