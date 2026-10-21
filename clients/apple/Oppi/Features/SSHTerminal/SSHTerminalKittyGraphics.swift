import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO

enum SSHTerminalKittyGraphics {
    /// Decoded image bytes kept per screen, shared by the terminal's store and
    /// the renderer's texture cache so neither outgrows the other.
    static let imageStorageLimitBytes = 64 * 1024 * 1024
}

/// Z classification of a placement, from the kitty protocol's z-index.
/// `belowBackground` is drawn under the cell background, `belowText` between
/// the background and the glyphs, `aboveText` over both.
enum SSHTerminalKittyLayer: Int, CaseIterable {
    case belowBackground
    case belowText
    case aboveText

    /// libghostty's own classification, so the embedder never re-derives it:
    /// z < INT32_MIN/2 is below the background, negative is below text.
    init?(_ layer: GhosttyKittyPlacementLayer) {
        switch layer {
        case GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG: self = .belowBackground
        case GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT: self = .belowText
        case GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT: self = .aboveText
        default: return nil
        }
    }
}

/// One Kitty graphics placement resolved into this viewport. Only real
/// placements appear here: libghostty reports no geometry for Unicode
/// placeholder (virtual) placements, so those are skipped (see
/// docs/ssh-terminal.md).
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
    /// Borrowed from libghostty: valid only until the terminal is mutated
    /// (any write, resize or reset). The engine refreshes it before every
    /// frame, and the renderer copies it into a texture during that same call.
    var pixels: UnsafePointer<UInt8>?
    var byteCount: Int

    var hasPixels: Bool { pixels != nil && byteCount == width * height * format.bytesPerPixel }
}

/// One screen's Kitty graphics for the current viewport. The engine replaces
/// the placement array when image storage or placement geometry changes, and
/// refreshes the borrowed image pointers in place because libghostty
/// invalidates them on every terminal mutation. Frames carry a reference;
/// they are only read synchronously on the main actor.
final class SSHTerminalKittySnapshot {
    private(set) var generation: UInt64
    private(set) var placements: [SSHTerminalKittyPlacement]
    private(set) var images: [SSHTerminalKittyImage]
    /// Terminal cell size these placements were resolved with.
    let cellWidth: Int
    let cellHeight: Int

    init(
        generation: UInt64,
        placements: [SSHTerminalKittyPlacement],
        images: [SSHTerminalKittyImage],
        cellWidth: Int,
        cellHeight: Int
    ) {
        self.generation = generation
        self.placements = placements
        self.images = images
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    var isEmpty: Bool { placements.isEmpty && images.isEmpty }

    /// Refresh the borrowed pixel pointers. libghostty invalidates every handle
    /// borrowed from the terminal on a mutating call, so the engine calls this
    /// before handing the snapshot to a renderer.
    func refreshImageData(_ graphics: GhosttyKittyGraphics) {
        for index in images.indices {
            guard let image = ghostty_kitty_graphics_image(graphics, images[index].id) else {
                images[index].pixels = nil
                images[index].byteCount = 0
                continue
            }
            var pixels: UnsafePointer<UInt8>?
            var length = 0
            if ghostty_kitty_graphics_image_get(
                image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pixels
            ) != GHOSTTY_SUCCESS { pixels = nil }
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
            images[index].pixels = pixels
            images[index].byteCount = length
        }
    }

    /// Read one stored image's metadata and pixels. A payload libghostty has
    /// not finished assembling reports `GHOSTTY_NO_VALUE` for the pointer; the
    /// next snapshot retries once the store's generation moves.
    static func image(_ image: GhosttyKittyGraphicsImage) -> SSHTerminalKittyImage {
        var id: UInt32 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var generation: UInt64 = 0
        var pixels: UnsafePointer<UInt8>?
        var length = 0
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_ID, &id)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
        if ghostty_kitty_graphics_image_get(
            image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pixels
        ) != GHOSTTY_SUCCESS { pixels = nil }
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        return SSHTerminalKittyImage(
            id: id, generation: generation,
            width: Int(width), height: Int(height),
            format: SSHTerminalKittyImageFormat(format) ?? .rgba,
            pixels: pixels, byteCount: length
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
        guard let source = CGImageSourceCreateWithData(
            Data(bytes: data, count: length) as CFData, nil
        ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }
        let byteCount = width * height * 4
        guard let buffer = ghostty_alloc(allocator, byteCount) else { return false }
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
        Self.unpremultiply(buffer, pixelCount: width * height)
        out.pointee.width = UInt32(width)
        out.pointee.height = UInt32(height)
        out.pointee.data = buffer
        out.pointee.data_len = byteCount
        return true
    }

    /// CGContext only writes premultiplied RGBA; the protocol, and therefore
    /// the renderer's blending, expects straight alpha.
    private static func unpremultiply(_ buffer: UnsafeMutablePointer<UInt8>, pixelCount: Int) {
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let alpha = Int(buffer[offset + 3])
            switch alpha {
            case 255: continue
            case 0: buffer[offset] = 0; buffer[offset + 1] = 0; buffer[offset + 2] = 0
            default:
                buffer[offset] = UInt8((Int(buffer[offset]) * 255 + alpha / 2) / alpha)
                buffer[offset + 1] = UInt8((Int(buffer[offset + 1]) * 255 + alpha / 2) / alpha)
                buffer[offset + 2] = UInt8((Int(buffer[offset + 2]) * 255 + alpha / 2) / alpha)
            }
        }
    }
}
