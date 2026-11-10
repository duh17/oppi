import UIKit
import UniformTypeIdentifiers

/// A file no other renderer draws: its type and size, and Share.
final class BinaryFileRenderer: FileRenderer {
    private let data: Data
    private let fileName: String

    private init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    static func load(_ file: FileRenderInput) async throws -> BinaryFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        return BinaryFileRenderer(data: read.data, fileName: file.fileName)
    }

    func mount(in host: FileRendererHost) -> UIView {
        host.unavailable(.empty(
            title: fileName,
            systemImage: "doc.fill",
            message: FileViewerBinarySummary.text(fileName: fileName, byteCount: data.count)
        ))
    }

    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem? {
        FileShareService.ShareableContent.fileData(data, filename: fileName).shareBarItem
    }
}

/// The generic file view's description of a file no viewer renders: its type and size.
enum FileViewerBinarySummary {
    static func text(fileName: String, byteCount: Int) -> String {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)?.localizedDescription
            ?? String(localized: "Binary file")
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return String(localized: "\(type) · \(size)")
    }
}
