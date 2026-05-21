import Testing
import UIKit
@testable import Oppi

@Suite("PendingImage")
@MainActor
struct PendingImageTests {
    @Test func imageUploadKeepsFullResolution() throws {
        let image = makeImage(width: 2_400, height: 1_600)

        let pending = PendingImage.from(image)
        let data = try #require(Data(base64Encoded: pending.attachment.data))
        let decoded = try #require(UIImage(data: data))

        #expect(pending.attachment.mimeType == "image/jpeg")
        #expect(Int(decoded.size.width.rounded()) == 2_400)
        #expect(Int(decoded.size.height.rounded()) == 1_600)
    }

    @Test func pickedJPEGDataPassesThroughWithoutReencoding() throws {
        let image = makeImage(width: 320, height: 180)
        let originalData = try #require(image.jpegData(compressionQuality: 0.73))

        let pending = PendingImage.from(data: originalData, mimeType: "image/jpeg", image: image)
        let uploadedData = try #require(Data(base64Encoded: pending.attachment.data))

        #expect(pending.attachment.mimeType == "image/jpeg")
        #expect(uploadedData == originalData)
    }

    @Test func uploadAttachmentWithoutAutoResizePreservesOriginalData() throws {
        let image = makeImage(width: 2_400, height: 1_600)
        let pending = PendingImage.from(image)

        let upload = PendingImage.uploadAttachment(from: pending.attachment, autoResize: false)

        #expect(upload == pending.attachment)
    }

    @Test func uploadAttachmentWithAutoResizeLeavesSmallImageUntouched() throws {
        let image = makeImage(width: 320, height: 180)
        let originalData = try #require(image.jpegData(compressionQuality: 0.73))
        let attachment = ImageAttachment(
            data: originalData.base64EncodedString(),
            mimeType: "image/jpeg"
        )

        let upload = PendingImage.uploadAttachment(from: attachment, autoResize: true)

        #expect(upload == attachment)
    }

    @Test func uploadAttachmentWithAutoResizeDownsamplesLargeImage() throws {
        let image = makeImage(width: 2_400, height: 1_600)
        let pending = PendingImage.from(image)

        let upload = PendingImage.uploadAttachment(from: pending.attachment, autoResize: true)
        let data = try #require(Data(base64Encoded: upload.data))
        let decoded = try #require(UIImage(data: data))
        let cgImage = try #require(decoded.cgImage)

        #expect(upload.data != pending.attachment.data)
        #expect(max(cgImage.width, cgImage.height) == 2_000)
        #expect(upload.mimeType == "image/png" || upload.mimeType == "image/jpeg")
    }

    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }
}
