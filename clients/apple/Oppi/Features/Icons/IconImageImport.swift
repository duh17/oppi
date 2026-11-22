import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Turns a picked image into the bytes an image icon uploads.
///
/// A still image of any format ImageIO decodes (a HEIC or JPEG photo included)
/// becomes a PNG at most 128 px on a side. An animated WebP is kept as it is when
/// it fits the server's caps (1 MiB, 1,024 px on a side); a bigger one is refused
/// rather than re-encoded. WebP is the only animated icon format, so a GIF is
/// refused with a message that asks for one. The result must also pass the decoder every icon
/// draws through (`IconAssetCache.decodeRemoteIcon`), which draws the first frame:
/// an image whose first frame is blank is refused, so nothing is saved that would
/// show the fallback symbol.
@MainActor
enum IconImageImport {
    /// The server's caps on an imported image (`ICON_IMAGE_MAX_BYTES`,
    /// `ICON_IMAGE_MAX_DIMENSION`).
    static let maxUploadBytes = 1024 * 1024
    static let maxAnimatedDimension = 1_024
    static let stillPixelSize = 128
    /// The upload's Content-Type. The server reads the format from the bytes.
    static let uploadContentType = "application/octet-stream"

    enum Failure: LocalizedError, Equatable {
        case undecodable
        case gifUnsupported
        case animatedTooLarge
        case blankFirstFrame

        var errorDescription: String? {
            switch self {
            case .undecodable:
                String(localized: "This file isn’t an image Oppi can read.")
            case .gifUnsupported:
                String(localized: "GIF isn’t supported. Use WebP for an animated icon.")
            case .animatedTooLarge:
                String(localized: "Animated images can be at most 1 MB, 1,024 pixels on a side, and 600 frames. Choose a smaller one.")
            case .blankFirstFrame:
                String(localized: "This image’s first frame is empty, so it would show as a blank icon. Choose another one.")
            }
        }
    }

    static func prepare(_ data: Data) throws(Failure) -> Data {
        let prepared = try encode(data)
        // The same decode the icon draws through: what passes here can be shown.
        do {
            _ = try IconAssetCache.decodeRemoteIcon(data: prepared, size: CGFloat(stillPixelSize))
        } catch {
            throw .blankFirstFrame
        }
        return prepared
    }

    private static func encode(_ data: Data) throws(Failure) -> Data {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              CGImageSourceGetCount(source) >= 1 else {
            throw .undecodable
        }

        if type.conforms(to: .gif) { throw .gifUnsupported }

        // A WebP keeps its frames; every other format uploads as one still PNG.
        if CGImageSourceGetCount(source) > 1, type.conforms(to: .webP) {
            guard data.count <= maxUploadBytes, fitsAnimatedDimension(source),
                  CGImageSourceGetCount(source) <= IconAssetCache.maxFrameCount else { throw .animatedTooLarge }
            guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw .undecodable }
            return data
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: stillPixelSize,
        ] as CFDictionary
        guard let still = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw .undecodable
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw .undecodable
        }
        CGImageDestinationAddImage(destination, still, nil)
        guard CGImageDestinationFinalize(destination) else { throw .undecodable }
        return png as Data
    }

    private static func fitsAnimatedDimension(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return false
        }
        return width <= maxAnimatedDimension && height <= maxAnimatedDimension
    }
}

/// Presents Photos or Files for one image and hands its prepared bytes back.
@MainActor
final class IconImageImporter: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    /// The prepared bytes of the image the person picked.
    var picked: (Data) -> Void = { _ in }
    /// A pick that could not be read or used, with the reason.
    var failed: (String) -> Void = { _ in }

    func presentPhotos(from presenter: UIViewController) {
        let picker = PHPickerViewController(
            configuration: PhotoLibraryPicker.makeConfiguration(selectionLimit: 1, filter: .images)
        )
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func presentFiles(from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        // The original representation, so an animated WebP stays animated.
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else {
            failed(IconImageImport.Failure.undecodable.localizedDescription)
            return
        }
        _ = provider.loadDataRepresentation(for: type) { [weak self] data, _ in
            Task { @MainActor in self?.deliver(data) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        Task { [weak self] in
            let data = await Task.detached { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
            self?.deliver(data)
        }
    }

    private func deliver(_ data: Data?) {
        guard let data else {
            failed(IconImageImport.Failure.undecodable.localizedDescription)
            return
        }
        do {
            picked(try IconImageImport.prepare(data))
        } catch {
            failed(error.localizedDescription)
        }
    }
}
