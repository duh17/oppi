import UIKit

/// Shows one preview category in the file viewer (`FileViewerViewController`).
///
/// The viewer picks the renderer for a file's `FileKind.previewCategory`
/// through `FileRendererRegistry`, calls `load`, keeps the result as its
/// rendered-file state, and `mount`s it. Text is not a renderer: the viewer's
/// reader and editor share the file's edit owner.
///
/// A renderer instance lives as long as the viewer shows its file. Everything
/// but `load` and `mount` has a default; a renderer implements only the hooks
/// it needs.
@MainActor
protocol FileRenderer: AnyObject {
    /// Reads `file` and holds what `mount` shows. Nil when the viewer moved to
    /// another file meanwhile.
    static func load(_ file: FileRenderInput) async throws -> Self?
    /// The page for the loaded file, added to `host`'s page.
    func mount(in host: FileRendererHost) -> UIView

    /// The page handles a horizontal back swipe itself (paging, 3D drag).
    var ownsBackSwipe: Bool { get }
    /// Showing the same file again keeps this renderer and its player instead
    /// of reading the file again (a full-screen modal over it, a resize).
    var keepsOnReshow: Bool { get }
    /// The viewer drops this renderer when it leaves the screen, and reads
    /// the file again when it comes back.
    var releasesOffScreen: Bool { get }
    /// Runs in the load after the page shows: reads that can follow it.
    func finishLoading() async
    /// Called on every viewer update: theme colors and observed player state.
    func update(palette: ThemePalette)
    func viewerDidAppear()
    func viewerDidDisappear()
    /// The viewer stopped showing this renderer: free what it holds.
    func release()
    /// The bar's Share item, or nil when the file is not shareable from here.
    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem?
}

extension FileRenderer {
    var ownsBackSwipe: Bool { false }
    var keepsOnReshow: Bool { false }
    var releasesOffScreen: Bool { false }
    func finishLoading() async {}
    func update(palette: ThemePalette) {}
    func viewerDidAppear() {}
    func viewerDidDisappear() {}
    func release() {}
    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem? { nil }
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

extension FileShareService.ShareableContent {
    /// The viewer's titled Share item for content it holds in memory.
    @MainActor var shareBarItem: UIBarButtonItem {
        let item = FileSharePresenter.makeShareBarButtonItem(for: self)
        item.title = String(localized: "Share")
        return item
    }
}
