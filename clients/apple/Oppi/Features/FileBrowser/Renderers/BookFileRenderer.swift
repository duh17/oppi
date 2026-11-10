import UIKit

/// A downloaded EPUB in the reader: one chapter at a time with its own TOC
/// and Previous/Next, at the position this book was left.
final class BookFileRenderer: FileRenderer {
    private let book: EPUBBook
    private let file: FileRenderInput
    /// The host path the server resolved the file to, when it reported one.
    private let resolvedHostPath: String?

    private init(book: EPUBBook, file: FileRenderInput, resolvedHostPath: String?) {
        self.book = book
        self.file = file
        self.resolvedHostPath = resolvedHostPath
    }

    static func load(_ file: FileRenderInput) async throws -> BookFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        let book = try EPUBBook.open(data: read.data)
        return BookFileRenderer(book: book, file: file, resolvedHostPath: read.resolvedHostPath)
    }

    /// The reader handles the back swipe itself, as it does for text.
    var ownsBackSwipe: Bool { true }

    /// Where this file came from. A book's saved position is keyed by it, so
    /// two books at one path in two workspaces, two sessions, or on the host
    /// do not share one slot.
    private var origin: String {
        let access = file.access
        return switch access.source {
        case .workspaceFile: "workspace:\(access.workspaceId)"
        case .sessionFile(let sessionId): "session:\(sessionId)"
        case .hostFile: "host"
        case .sessionTouched(let origin): "session:\(origin.sessionId)"
        }
    }

    func mount(in host: FileRendererHost) -> UIView {
        let path = resolvedHostPath ?? file.path
        let document = EPUBReaderDocument(
            book: book,
            positionKey: EPUBReadingPositionStore.key(
                serverId: file.access.serverId,
                origin: origin,
                path: path
            ),
            filePath: path,
            title: book.title.isEmpty ? file.fileName : book.title
        )
        return host.mountReader(.book(document))
    }
}
