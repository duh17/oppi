import LinkPresentation
import PDFKit
import UIKit

/// What a pin's tile shows beyond its name: a file's first page or picture,
/// a folder's size and first items, a game's last frame and build, a web
/// page's title and pictures.
struct PinPreview: Equatable, Sendable {
    /// A file's thumbnail, a game's last frame, a web page's image.
    var image: UIImage?
    /// A web page's icon.
    var icon: UIImage?
    /// A web page's title.
    var title: String?
    /// "PDF · 2 pages · 277.9 KB", "9 items", "Godot 4.7 · Build 72".
    var detail: String?
    /// A folder's first items, folders first.
    var children: [FileEntry] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.icon === rhs.icon && lhs.title == rhs.title
            && lhs.detail == rhs.detail && lhs.children == rhs.children
    }
}

/// Reads each pin's preview the first time a screen asks for it, and again
/// after `refresh()` (each time the screen appears). Observed: a screen that
/// reads `preview(for:)` in `updateProperties()` redraws when one arrives,
/// and keeps the one it has until the next read answers.
///
/// Thumbnails are the expensive part, so they live in `cache` for the app's
/// life under the file's version (size and modification time, read with a
/// `HEAD`): an unchanged file is never read again, a changed one is. PDF
/// pages and pictures render off the main actor; a game's picture is the
/// frame this device's Godot pane kept (`GodotFolders.poster`).
@MainActor @Observable
final class PinPreviewStore {
    private(set) var previews: [String: PinPreview] = [:]
    @ObservationIgnored private var started: Set<String> = []

    /// The largest file read for a thumbnail.
    nonisolated static let thumbnailLimit = 30 * 1024 * 1024
    /// A thumbnail's longer side, in pixels.
    nonisolated static let thumbnailPixels: CGFloat = 480
    /// Thumbnails and page metadata by server, pin, and file version.
    private static let cache = NSCache<NSString, PreviewBox>()

    private final class PreviewBox {
        let preview: PinPreview
        init(_ preview: PinPreview) { self.preview = preview }
    }

    /// The preview read so far for `pin` on `serverId`; starts reading it
    /// the first time, or the first time since `refresh()`.
    func preview(for pin: Pin, serverId: String, connection: ServerConnection) -> PinPreview? {
        let key = "\(serverId)|\(pin.target.pinKey)"
        if !started.contains(key), !pin.isGone, let api = connection.apiClient {
            started.insert(key)
            let target = pin.target
            Task { [weak self] in
                guard let preview = await Self.load(target, serverId: serverId, key: key, api: api) else { return }
                if self?.previews[key] != preview { self?.previews[key] = preview }
            }
        }
        return previews[key]
    }

    /// Reads every preview again the next time it is asked for.
    func refresh() {
        started.removeAll()
    }

    private static func load(_ route: PaneRoute, serverId: String, key: String, api: APIClient) async -> PinPreview? {
        switch route {
        case .file(let origin, let path, _):
            let current: APIClient.CurrentFileOrigin = switch origin {
            case .host: .host(controlSessionId: nil)
            case .workspace(let id, let worktree): .workspace(workspaceId: id, worktreeId: worktree)
            case .session(let id): .session(sessionId: id)
            }
            return await file(current, path: path, key: key, api: api)
        case .hostFiles(let path):
            return await folder { after in
                try await api.listHostDirectory(path: FileBrowserHostHomePath.directoryPath(rawPath: path ?? "~"), after: after)
            }
        case .files(let workspace, let path):
            return await folder { after in
                try await api.listWorkspaceDirectory(workspaceId: workspace, path: path.map { $0 + "/" } ?? "", after: after)
            }
        case .godot(let project):
            return await game(GodotSlot(serverId: serverId, project: project), api: api)
        case .browser(let url):
            return await page(url, key: key)
        default:
            return nil
        }
    }

    // MARK: Files

    private enum Thumbnail {
        case pdf, image

        init?(path: String) {
            switch (path as NSString).pathExtension.lowercased() {
            case "pdf": self = .pdf
            case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp": self = .image
            default: return nil
            }
        }
    }

    private static func file(_ origin: APIClient.CurrentFileOrigin, path: String, key: String, api: APIClient) async -> PinPreview? {
        guard let kind = Thumbnail(path: path),
              let version = try? await api.currentFileVersion(origin, path: path),
              version.size <= thumbnailLimit else { return nil }
        let cacheKey = "\(key)|\(version.size)|\(version.modified)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.preview }
        guard let data = try? await api.currentFile(origin, path: path) else { return nil }
        let size = SessionFormatting.byteCount(data.count)
        let preview = await Task.detached(priority: .utility) { () -> PinPreview? in
            switch kind {
            case .pdf: return pdfPreview(data, size: size)
            case .image: return imagePreview(data, size: size, ext: (path as NSString).pathExtension.uppercased())
            }
        }.value
        if let preview { cache.setObject(PreviewBox(preview), forKey: cacheKey) }
        return preview
    }

    /// The first page and the page count.
    nonisolated private static func pdfPreview(_ data: Data, size: String) -> PinPreview? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let scale = thumbnailPixels / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
        let pages = document.pageCount == 1 ? String(localized: "1 page") : String(localized: "\(document.pageCount) pages")
        return PinPreview(image: image, detail: "PDF \u{00B7} \(pages) \u{00B7} \(size)")
    }

    /// The picture, scaled down, and its pixel size.
    nonisolated private static func imagePreview(_ data: Data, size: String, ext: String) -> PinPreview? {
        guard let image = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, thumbnailPixels / max(pixels.width, pixels.height, 1))
        let thumbnail = image.preparingThumbnail(of: CGSize(width: pixels.width * scale, height: pixels.height * scale)) ?? image
        return PinPreview(image: thumbnail, detail: "\(ext) \u{00B7} \(Int(pixels.width))\u{00D7}\(Int(pixels.height)) \u{00B7} \(size)")
    }

    // MARK: Folders

    /// The first page's count (with a + when more follow) and first items;
    /// hidden items are not counted.
    private static func folder(_ list: (String?) async throws -> DirectoryListingResponse) async -> PinPreview? {
        guard let page = try? await list(nil) else { return nil }
        let visible = page.entries.filter { !$0.name.hasPrefix(".") }
        let items = switch (visible.count, page.truncated) {
        case (let count, true): String(localized: "\(count)+ items")
        case (0, false): String(localized: "Empty")
        case (1, false): String(localized: "1 item")
        case (let count, false): String(localized: "\(count) items")
        }
        let ordered = visible.sorted { lhs, rhs in
            lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return PinPreview(detail: items, children: Array(ordered.prefix(4)))
    }

    // MARK: Games

    /// The game's engine and build, and the frame this device last showed of it.
    private static func game(_ slot: GodotSlot, api: APIClient) async -> PinPreview? {
        async let poster = Task.detached(priority: .utility) { () -> UIImage? in
            guard let image = UIImage(contentsOfFile: GodotFolders.poster(for: slot).path) else { return nil }
            let scale = min(1, thumbnailPixels / max(image.size.width, image.size.height, 1))
            return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        }.value
        let project = try? await GodotLinkClient(api: api, playerLink: { _ in nil }).project(slot.project)
        var parts: [String] = []
        if let version = project?.engine.version { parts.append("Godot \(version)") }
        if let release = project?.release { parts.append(String(localized: "Build \(release.seq)")) }
        return PinPreview(image: await poster, detail: parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} "))
    }

    // MARK: Web pages

    /// The page's title, icon, and image, as a shared link shows them.
    private static func page(_ url: URL, key: String) async -> PinPreview? {
        if let cached = cache.object(forKey: key as NSString) { return cached.preview }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let title = metadata.title
        let image = await Self.image(metadata.imageProvider)
        let icon = await Self.image(metadata.iconProvider)
        let preview = PinPreview(image: image, icon: icon, title: title)
        cache.setObject(PreviewBox(preview), forKey: key as NSString)
        return preview
    }

    private static func image(_ provider: NSItemProvider?) async -> UIImage? {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let image = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let image else { return nil }
        let scale = min(1, thumbnailPixels / max(image.size.width * image.scale, image.size.height * image.scale, 1))
        return await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)) ?? image
    }
}
