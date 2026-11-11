import UIKit
import UniformTypeIdentifiers

/// What Share sends for one file of the File Browser or its viewer. Either
/// way the share sheet gets the real file under its own name.
enum ShareableFile {
    /// Bytes the viewer already holds, with the rendered exports they have
    /// (an image or PDF of Markdown or code) beside the file itself.
    case loaded(FileShareService.ShareableContent)
    /// A file still on the server: a list row, or media the viewer streams.
    case remote(RemoteFileShare)
}

/// A file still on the server. Share downloads it to a temporary file first,
/// with progress the person can cancel (`FileSharePresenter.share`).
struct RemoteFileShare {
    let fileName: String
    /// The size the folder listing gave, for progress when the response
    /// states no length.
    let expectedBytes: Int64?
    /// Writes the whole file to `destination`. Throws `FileDownloadError`
    /// when the server refuses, `CancellationError` when cancelled.
    let download: @MainActor (
        _ destination: URL,
        _ onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) async throws -> Void
}

/// A file handed to the share sheet as its URL, typed as the file-kind table
/// types its name (`FileKind.contentType`), so the receiving app knows a video
/// from a scene from a book whatever the system makes of the extension.
final class FileActivityItemSource: NSObject, UIActivityItemSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var contentType: UTType {
        FileKind.contentType(forPath: url.lastPathComponent)
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        contentType.identifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        url.lastPathComponent
    }
}
