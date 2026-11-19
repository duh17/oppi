import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

extension XCUIScreenshot {
    /// The screenshot as a PNG whose pixels are upright, with no orientation
    /// tag. In landscape, `pngRepresentation` keeps the portrait canvas and
    /// adds an EXIF/XMP orientation (8), so tools that ignore the tag show the
    /// image sideways and tools that rotate it again turn it twice. Every
    /// screenshot a test writes or attaches goes through this.
    var uprightPNG: Data {
        let image = image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        // `size` is the upright size; drawing applies the image's orientation.
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        // ImageIO with no properties writes no EXIF at all; `pngData()` would
        // still tag the file with orientation 1.
        let data = NSMutableData()
        guard let cgImage = upright.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            preconditionFailure("A rendered screenshot always has a CGImage and ImageIO always writes PNG")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        precondition(CGImageDestinationFinalize(destination), "ImageIO could not write the screenshot PNG")
        return data as Data
    }
}

extension XCTAttachment {
    /// An attachment of `screenshot` as an upright PNG (`XCUIScreenshot.uprightPNG`).
    convenience init(uprightScreenshot screenshot: XCUIScreenshot) {
        self.init(data: screenshot.uprightPNG, uniformTypeIdentifier: UTType.png.identifier)
    }
}
