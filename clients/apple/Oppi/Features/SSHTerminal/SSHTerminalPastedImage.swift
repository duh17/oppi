import UIKit
import UniformTypeIdentifiers

/// A pasted image as the bytes the clipboard held and a file extension the
/// host file can carry, so the agent sees a PNG, JPEG, or HEIC as such.
struct SSHTerminalPastedImage: Equatable {
    let data: Data
    let fileExtension: String

    init(data: Data, type: UTType) {
        self.data = data
        fileExtension = type.preferredFilenameExtension ?? "png"
    }

    init?(pasteboard: UIPasteboard) {
        for identifier in pasteboard.types {
            guard let type = UTType(identifier), type.conforms(to: .image),
                  let data = pasteboard.data(forPasteboardType: identifier) else { continue }
            self.init(data: data, type: type)
            return
        }
        guard let data = pasteboard.image?.pngData() else { return nil }
        self.init(data: data, type: .png)
    }

    static func imageType(in provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.lazy.compactMap { UTType($0) }.first { $0.conforms(to: .image) }
    }
}
