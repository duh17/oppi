import AppKit
import Foundation

struct MacSessionFilePreview: Sendable, Equatable {
    static let maxPreviewCharacters = 16_000

    let path: String
    let fileType: FileType
    let kind: MacSessionFilePreviewKind
    let text: String?
    let imageData: Data?
    let imageWidth: Double?
    let imageHeight: Double?
    let byteCount: Int
    let truncated: Bool

    init(path: String, data: Data) {
        self.path = path
        byteCount = data.count

        if let decoded = String(data: data, encoding: .utf8) {
            fileType = FileType.detect(from: path, content: decoded)
            kind = .text
            imageData = nil
            imageWidth = nil
            imageHeight = nil
            if decoded.count > Self.maxPreviewCharacters {
                text = String(decoded.prefix(Self.maxPreviewCharacters))
                truncated = true
            } else {
                text = decoded
                truncated = false
            }
            return
        }

        fileType = FileType.detect(from: path)

        if let image = NSImage(data: data) {
            kind = .image
            text = nil
            imageData = data
            imageWidth = image.size.width
            imageHeight = image.size.height
            truncated = false
            return
        }

        kind = .binary
        text = nil
        imageData = nil
        imageWidth = nil
        imageHeight = nil
        truncated = false
    }

    var sourceLanguageLabel: String? {
        switch fileType {
        case .code(let language):
            return language.displayName
        case .json:
            return SyntaxLanguage.json.displayName
        case .html:
            return SyntaxLanguage.html.displayName
        case .markdown:
            return "Markdown"
        case .latex:
            return SyntaxLanguage.latex.displayName
        case .orgMode:
            return SyntaxLanguage.orgMode.displayName
        case .mermaid:
            return SyntaxLanguage.mermaid.displayName
        case .graphviz:
            return SyntaxLanguage.dot.displayName
        case .plain, .image, .audio, .video, .pdf, .binary:
            return nil
        }
    }

    var displayDetail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        switch kind {
        case .text:
            let suffix = truncated ? " · Preview truncated" : ""
            return "\(size) · \(fileType.displayLabel)\(suffix)"
        case .image:
            if let imageWidth, let imageHeight {
                return "\(size) · \(Int(imageWidth))×\(Int(imageHeight))"
            }
            return size
        case .binary:
            return "\(size) · Binary file"
        }
    }
}

enum MacSessionFilePreviewKind: String, Sendable, Equatable {
    case text
    case image
    case binary

    var systemImage: String {
        switch self {
        case .text: "doc.text.magnifyingglass"
        case .image: "photo"
        case .binary: "doc.badge.gearshape"
        }
    }
}
