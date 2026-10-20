import UIKit

/// An image queued for sending. Holds a thumbnail for display and
/// full-resolution image data + base64 for upload.
struct PendingImage: Identifiable, Sendable {
    let id: String
    let thumbnail: UIImage
    let attachment: ImageAttachment

    private typealias EncodedImage = (data: Data, mimeType: String)

    static let autoResizeMaxDimension: CGFloat = 2_000
    static let autoResizeMaxBase64Bytes = 4_718_592
    static let autoResizeMaxDataBytes = (autoResizeMaxBase64Bytes / 4) * 3
    private static let autoResizeJPEGQualities: [CGFloat] = [0.8, 0.85, 0.7, 0.55, 0.4]

    var pendingAttachment: PendingAttachment {
        PendingAttachment(
            id: id,
            source: .image,
            displayName: "Image",
            thumbnail: thumbnail,
            imageAttachment: attachment,
            localFileData: nil,
            localMimeType: nil
        )
    }

    static func from(data: Data, mimeType: String?, image: UIImage) -> Self {
        if let sendableMimeType = sendableOriginalMimeType(data: data, declaredMimeType: mimeType) {
            return Self(
                id: UUID().uuidString,
                thumbnail: downsample(image, maxDimension: 112),
                attachment: ImageAttachment(
                    data: data.base64EncodedString(),
                    mimeType: sendableMimeType
                )
            )
        }
        return from(image)
    }

    static func from(_ image: UIImage) -> Self {
        let thumb = downsample(image, maxDimension: 112)
        let imageData = image.jpegData(compressionQuality: 1.0) ?? image.pngData() ?? Data()
        let mimeType = sniffedMimeType(data: imageData) ?? "image/jpeg"
        return Self(
            id: UUID().uuidString,
            thumbnail: thumb,
            attachment: ImageAttachment(
                data: imageData.base64EncodedString(),
                mimeType: mimeType
            )
        )
    }

    static func uploadAttachment(from attachment: ImageAttachment, autoResize: Bool) -> ImageAttachment {
        guard autoResize,
              let originalData = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters),
              let image = UIImage(data: originalData) else {
            return attachment
        }

        let originalFitsDimensions = maxPixelDimension(for: image) <= autoResizeMaxDimension
        if originalFitsDimensions && base64ByteCount(for: originalData) <= autoResizeMaxBase64Bytes {
            return attachment
        }

        var workingImage = originalFitsDimensions
            ? image
            : downsample(image, maxDimension: autoResizeMaxDimension)
        var bestCandidate: EncodedImage?

        while true {
            for candidate in encodedCandidates(for: workingImage) {
                if let best = bestCandidate {
                    if candidate.data.count < best.data.count {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
                if base64ByteCount(for: candidate.data) <= autoResizeMaxBase64Bytes {
                    return ImageAttachment(
                        data: candidate.data.base64EncodedString(),
                        mimeType: candidate.mimeType
                    )
                }
            }

            let currentSize = pixelSize(for: workingImage)
            let nextSize = CGSize(
                width: max(1, floor(currentSize.width * 0.75)),
                height: max(1, floor(currentSize.height * 0.75))
            )
            guard nextSize.width < currentSize.width || nextSize.height < currentSize.height else {
                break
            }
            workingImage = render(workingImage, size: nextSize)
        }

        guard let bestCandidate else { return attachment }
        return ImageAttachment(
            data: bestCandidate.data.base64EncodedString(),
            mimeType: bestCandidate.mimeType
        )
    }

    private static func sendableOriginalMimeType(data: Data, declaredMimeType: String?) -> String? {
        if let sniffed = sniffedMimeType(data: data) {
            return sniffed
        }
        switch normalizedMimeType(declaredMimeType) {
        case "image/jpeg", "image/jpg": return "image/jpeg"
        case "image/png": return "image/png"
        case "image/gif": return "image/gif"
        case "image/webp": return "image/webp"
        default: return nil
        }
    }

    private static func normalizedMimeType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        return mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sniffedMimeType(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if data.count >= 12,
           data.prefix(4).elementsEqual(Array("RIFF".utf8)),
           data.dropFirst(8).prefix(4).elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }

    private static func encodedCandidates(for image: UIImage) -> [EncodedImage] {
        var candidates: [EncodedImage] = []
        if let pngData = image.pngData() {
            candidates.append((pngData, "image/png"))
        }
        for quality in autoResizeJPEGQualities {
            if let jpegData = image.jpegData(compressionQuality: quality) {
                candidates.append((jpegData, "image/jpeg"))
            }
        }
        return candidates
    }

    private static func base64ByteCount(for data: Data) -> Int {
        ((data.count + 2) / 3) * 4
    }

    private static func maxPixelDimension(for image: UIImage) -> CGFloat {
        let size = pixelSize(for: image)
        return max(size.width, size.height)
    }

    private static func pixelSize(for image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return image.size
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = pixelSize(for: image)
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1.0 { return image }
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        return render(image, size: newSize)
    }

    private static func render(_ image: UIImage, size: CGSize) -> UIImage {
        let renderSize = CGSize(
            width: max(1, floor(size.width)),
            height: max(1, floor(size.height))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }
}
