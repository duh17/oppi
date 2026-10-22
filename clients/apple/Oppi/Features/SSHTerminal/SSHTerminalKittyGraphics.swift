import Accelerate
import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO

enum SSHTerminalKittyGraphics {
    /// Decoded image bytes kept per screen, shared by the terminal's store and
    /// the renderer's texture cache so neither outgrows the other.
    static let imageStorageLimitBytes = 64 * 1024 * 1024
    /// Largest accepted width or height. A store-size check alone would still
    /// let a PNG bomb name a huge canvas, so the shape is bounded first.
    static let maximumImageDimension = 10_000
}

/// Z classification of a placement, from the kitty protocol's z-index.
/// `belowBackground` is drawn under the cell background, `belowText` between
/// the background and the glyphs, `aboveText` over both.
enum SSHTerminalKittyLayer: Int, CaseIterable {
    case belowBackground
    case belowText
    case aboveText

    /// libghostty's own classification, used as the placement iterator's layer
    /// filter: z < INT32_MIN/2 is below the background, negative is below text,
    /// zero or more above it. Keeping the thresholds library-side means the
    /// embedder never re-derives them and a draw order cannot disagree.
    var ghosttyLayer: GhosttyKittyPlacementLayer {
        switch self {
        case .belowBackground: GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG
        case .belowText: GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT
        case .aboveText: GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT
        }
    }
}

/// One Kitty graphics placement resolved into this viewport. Only real
/// placements appear here: libghostty reports no geometry for Unicode
/// placeholder (virtual) placements, so those are skipped (see
/// docs/ssh-terminal.md). The layer comes from the iterator's own z filter.
struct SSHTerminalKittyPlacement: Equatable {
    let imageID: UInt32
    let layer: SSHTerminalKittyLayer
    /// Pixel offset from the top-left corner of the placement's cell.
    let xOffset: Int
    let yOffset: Int
    /// Destination size in terminal pixels, source aspect ratio applied.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Viewport-relative grid cell of the top-left corner. A row above the
    /// viewport is negative: the picture is pinned to its rows and clipped.
    let viewportColumn: Int
    let viewportRow: Int
    /// Source rectangle in image pixels.
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
}

/// Pixel layout of a stored image. libghostty stores every payload decoded and
/// uncompressed, so a renderer uploads these bytes without any decode step.
enum SSHTerminalKittyImageFormat: UInt32 {
    case rgb = 0
    case rgba = 1
    case grayAlpha = 3
    case gray = 4

    var bytesPerPixel: Int {
        switch self {
        case .rgb: 3
        case .rgba: 4
        case .grayAlpha: 2
        case .gray: 1
        }
    }

    init?(_ format: GhosttyKittyImageFormat) {
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: self = .rgb
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA: self = .rgba
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: self = .grayAlpha
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: self = .gray
        default: return nil
        }
    }
}

struct SSHTerminalKittyImage {
    let id: UInt32
    /// Changes whenever this image ID is retransmitted or replays a frame, so a
    /// texture cache keyed on it never shows stale pixels.
    let generation: UInt64
    let width: Int
    let height: Int
    let format: SSHTerminalKittyImageFormat

    /// Borrowed pixel payload for this image, resolved on demand: only a texture
    /// upload needs the bytes, so a frame whose textures are already uploaded
    /// makes no per-image calls at all. The pointer is valid only until the
    /// terminal is mutated, which is why the renderer copies it immediately.
    func resolvePixels(_ graphics: GhosttyKittyGraphics) -> SSHTerminalKittyPixels? {
        guard let image = ghostty_kitty_graphics_image(graphics, id) else { return nil }
        var pixels: UnsafePointer<UInt8>?
        if ghostty_kitty_graphics_image_get(
            image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pixels
        ) != GHOSTTY_SUCCESS { pixels = nil }
        var length = 0
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        // A payload libghostty has not finished assembling reports no pointer;
        // the next frame retries once the store's generation moves.
        guard let pixels, length == width * height * format.bytesPerPixel else { return nil }
        return SSHTerminalKittyPixels(pointer: pixels, byteCount: length)
    }
}

/// Borrowed pixel bytes of one stored image.
struct SSHTerminalKittyPixels {
    let pointer: UnsafePointer<UInt8>
    let byteCount: Int
}

/// One screen's Kitty graphics for the current viewport. The engine replaces the
/// placement array when image storage or placement geometry changes; pixel
/// payloads are not copied into it, so it costs no more than the geometry.
/// Frames carry a reference; they are only read synchronously on the main actor.
final class SSHTerminalKittySnapshot {
    /// libghostty's storage generation. It moves on any transmit, placement or
    /// delete, so a renderer can evict textures only when it changed.
    private(set) var generation: UInt64
    /// Sorted by layer, then image ID, so a renderer places every image in one
    /// linear pass with one draw per image and layer.
    private(set) var placements: [SSHTerminalKittyPlacement]
    private(set) var images: [SSHTerminalKittyImage]
    /// The same images by ID, built once when the snapshot is read so a frame
    /// looks each placement's image up instead of scanning the list.
    let imagesByID: [UInt32: SSHTerminalKittyImage]
    /// Every image ID libghostty still stores, on either screen, including
    /// images whose placements scrolled out of the viewport. Textures are evicted
    /// against this, not against what happens to be visible.
    let storedImageIDs: Set<UInt32>
    /// Terminal cell size these placements were resolved with.
    let cellWidth: Int
    let cellHeight: Int

    init(
        generation: UInt64,
        placements: [SSHTerminalKittyPlacement],
        images: [SSHTerminalKittyImage],
        imagesByID: [UInt32: SSHTerminalKittyImage],
        storedImageIDs: Set<UInt32>,
        cellWidth: Int,
        cellHeight: Int
    ) {
        self.generation = generation
        self.placements = placements
        self.images = images
        self.imagesByID = imagesByID
        self.storedImageIDs = storedImageIDs
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    var isEmpty: Bool { placements.isEmpty && images.isEmpty }

    /// Read one stored image's metadata. A payload libghostty has not finished
    /// assembling is not read here: `SSHTerminalKittyImage.resolvePixels` asks
    /// for it when an upload needs it.
    static func image(_ image: GhosttyKittyGraphicsImage) -> SSHTerminalKittyImage {
        var id: UInt32 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var generation: UInt64 = 0
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_ID, &id)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
        return SSHTerminalKittyImage(
            id: id, generation: generation,
            width: Int(width), height: Int(height),
            format: SSHTerminalKittyImageFormat(format) ?? .rgba
        )
    }
}

/// PNG decoding for Kitty graphics, through ImageIO. Process-global (one
/// install), and the only decoder libghostty is given: direct RGBA/RGB/zlib
/// payloads never reach it.
enum SSHTerminalKittyPNGDecoder {
    private static let installed: Void = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            decodePNG(data: data, length: length, allocator: allocator, out: out)
        }
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
    }()

    /// Idempotent. Must run before a terminal accepts PNG payloads.
    static func install() { _ = installed }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngType = "public.png"

    /// Decodes one PNG into the RGBA buffer libghostty owns. The library frees
    /// the buffer with the allocator it passed, so it is allocated with
    /// `ghostty_alloc` rather than `malloc`.
    private static func decodePNG(
        data: UnsafePointer<UInt8>?,
        length: Int,
        allocator: UnsafePointer<GhosttyAllocator>?,
        out: UnsafeMutablePointer<GhosttySysImage>?
    ) -> Bool {
        guard let data, length > 0, let out else { return false }
        // The payload belongs to libghostty and is only valid for the duration of
        // this callback. Borrow it for that long instead of copying a payload
        // that may already be tens of megabytes; nothing here may retain it.
        let encoded = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: length, deallocator: .none
        )
        // `f=100` means PNG, and the bytes come from whatever the terminal shows
        // (`cat` of a hostile file reaches here too). ImageIO sniffs the format,
        // so without these checks a payload would reach its JPEG, HEIC, TIFF, PSD,
        // GIF, and BMP decoders as well. Only a PNG signature, decoded as PNG, is
        // accepted.
        guard encoded.starts(with: pngSignature),
              let source = CGImageSourceCreateWithData(
                  encoded as CFData, [kCGImageSourceTypeIdentifierHint: pngType] as CFDictionary
              ),
              CGImageSourceGetType(source) as String? == pngType,
              let declared = declaredPixelSize(source),
              Self.allowedByteCount(width: declared.width, height: declared.height) != nil else {
            // Refused from the header alone: ImageIO has decoded nothing, so a
            // PNG that merely declares a huge canvas costs no memory.
            return false
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = image.width
        let height = image.height
        // A decoder may report a size other than the header claimed, so the same
        // overflow-checked guard runs again before anything is allocated.
        guard let byteCount = Self.allowedByteCount(width: width, height: height),
              let buffer = ghostty_alloc(allocator, byteCount) else { return false }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            ghostty_free(allocator, buffer, byteCount)
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard Self.unpremultiply(buffer, width: width, height: height) else {
            ghostty_free(allocator, buffer, byteCount)
            return false
        }
        out.pointee.width = UInt32(width)
        out.pointee.height = UInt32(height)
        out.pointee.data = buffer
        out.pointee.data_len = byteCount
        return true
    }

    /// Decoded RGBA byte count for this canvas, or nil when it must be refused.
    /// Every multiplication is overflow-checked, and the two dimension caps keep
    /// a width or height from ever reaching a `UInt32` conversion it cannot hold.
    static func allowedByteCount(
        width: Int,
        height: Int,
        limit: Int = SSHTerminalKittyGraphics.imageStorageLimitBytes
    ) -> Int? {
        guard width > 0, height > 0,
              width <= SSHTerminalKittyGraphics.maximumImageDimension,
              height <= SSHTerminalKittyGraphics.maximumImageDimension else { return nil }
        let (pixels, pixelsOverflowed) = width.multipliedReportingOverflow(by: height)
        guard !pixelsOverflowed else { return nil }
        let (bytes, bytesOverflowed) = pixels.multipliedReportingOverflow(by: 4)
        guard !bytesOverflowed, bytes <= limit else { return nil }
        return bytes
    }

    /// Pixel size from the image header, before any pixel is decoded.
    private static func declaredPixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// CGContext only writes premultiplied RGBA; the protocol, and therefore the
    /// renderer's blending, expects straight alpha. vImage does it with SIMD and
    /// clamps every channel to 255, so no byte division can trap or wrap.
    private static func unpremultiply(
        _ buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int
    ) -> Bool {
        var image = vImage_Buffer(
            data: buffer, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: width * 4
        )
        let error = withUnsafePointer(to: &image) { pointer in
            vImageUnpremultiplyData_RGBA8888(pointer, pointer, vImage_Flags(kvImageNoFlags))
        }
        return error == kvImageNoError
    }
}
