import CoreText
import GhosttyVt
import Metal
import QuartzCore
import UIKit

/// The terminal grid uses `AppFont.monoMedium` (13pt at 100% Code Text Size),
/// with Nerd Font symbols as a fallback once they are installed.
struct SSHTerminalCellMetrics {
    let cellSize: CGSize
    let font: UIFont
    let boldFont: UIFont

    init(font: UIFont, boldFont: UIFont) {
        self.font = font
        self.boldFont = boldFont
        cellSize = CGSize(
            width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
            height: ceil(font.lineHeight)
        )
    }

    static func codeFont() -> SSHTerminalCellMetrics {
        SSHTerminalCellMetrics(font: AppFont.monoMedium, boldFont: AppFont.monoMediumBold)
    }
}

/// Encode did not submit. Transient misses retry this same grid;
/// deterministic misses wait for a new changeCount, theme, font, or bounds.
enum SSHTerminalMetalEncodeMiss: Equatable, Sendable {
    case transient
    case deterministic
}

struct SSHTerminalMetalFrameCost: Sendable {
    var encodeNanos: UInt64
    var submitted: Bool
    var completed: Bool
    var status: MTLCommandBufferStatus
    var errorDescription: String?
    var miss: SSHTerminalMetalEncodeMiss? = nil
    var rebuiltRowCount: Int = 0
    var reusedRowCount: Int = 0
    /// Kitty graphics drawn this frame (one instance per visible placement).
    var imagePlacementCount: Int = 0
    /// Images whose pixels were copied into a texture this frame. Zero in the
    /// steady state; one per image generation when it changes.
    var imageUploadCount: Int = 0
}

/// Process-wide pipeline from the precompiled metallib. Built off the main
/// thread so first open does not stall on `makeRenderPipelineState`.
final class SSHTerminalMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let solid: MTLRenderPipelineState
    let overlay: MTLRenderPipelineState
    let glyph: MTLRenderPipelineState
    let image: MTLRenderPipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SSHTerminalMetalPipeline?
    nonisolated(unsafe) private static var cachedError: String?
    private static let buildQueue = DispatchQueue(label: "oppi.ssh-terminal.metal-pipeline")

    enum PipelineError: Error {
        case noDevice
        case noCommandQueue
        case noLibrary
        case missingFunction(String)
        case pipeline(String)
    }

    static func peek() -> SSHTerminalMetalPipeline? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    static func shared() throws -> SSHTerminalMetalPipeline {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        if let cachedError {
            lock.unlock()
            throw PipelineError.pipeline(cachedError)
        }
        lock.unlock()
        do {
            let built = try SSHTerminalMetalPipeline()
            lock.lock()
            cached = built
            lock.unlock()
            return built
        } catch {
            lock.lock()
            cachedError = String(describing: error)
            lock.unlock()
            throw error
        }
    }

    /// Pipeline creation must not block first open on main.
    static func prewarm() {
        buildQueue.async {
            _ = try? shared()
        }
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PipelineError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw PipelineError.noCommandQueue }
        let bundle = Bundle(for: SSHTerminalMetalPipeline.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            throw PipelineError.noLibrary
        }
        guard let vertex = library.makeFunction(name: "ssh_terminal_vertex") else {
            throw PipelineError.missingFunction("ssh_terminal_vertex")
        }
        guard let solidFn = library.makeFunction(name: "ssh_terminal_solid") else {
            throw PipelineError.missingFunction("ssh_terminal_solid")
        }
        guard let glyphFn = library.makeFunction(name: "ssh_terminal_glyph") else {
            throw PipelineError.missingFunction("ssh_terminal_glyph")
        }
        guard let imageFn = library.makeFunction(name: "ssh_terminal_image") else {
            throw PipelineError.missingFunction("ssh_terminal_image")
        }
        /// Cell instances are premultiplied; kitty image pixels are straight
        /// alpha, so they need the source-alpha blend factors.
        enum Blend {
            case none, premultiplied, straightAlpha
        }
        func pipeline(_ fragment: MTLFunction, blend: Blend) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blend != .none, let color = descriptor.colorAttachments[0] {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = blend == .straightAlpha ? .sourceAlpha : .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw PipelineError.pipeline(String(describing: error))
            }
        }
        self.device = device
        self.queue = queue
        self.solid = try pipeline(solidFn, blend: .none)
        self.overlay = try pipeline(solidFn, blend: .premultiplied)
        self.glyph = try pipeline(glyphFn, blend: .premultiplied)
        self.image = try pipeline(imageFn, blend: .straightAlpha)
    }
}

/// Core Text glyphs rasterized once at device scale, keyed by grapheme + face.
/// Coverage glyphs live in an R8 atlas; color emoji in RGBA. CPU packing only:
/// new ink reaches the private atlas through a blit in the same command buffer
/// as the draw, so a later frame cannot CPU-write texels an earlier buffer is
/// still sampling.
final class SSHTerminalGlyphAtlas {
    static let side = 2048
    let textTexture: MTLTexture
    /// 1×1 until the first color glyph, then a full-size RGBA atlas.
    private(set) var colorTexture: MTLTexture
    let side: Int
    private let device: MTLDevice
    private var map = [GlyphKey: CachedGlyph]()
    private var textPack = Packer()
    private var colorPack = Packer()
    private var colorAtlasReady = false

    struct GlyphKey: Hashable {
        var face: UInt8
        var scalar: UInt32
        var cluster: String
    }

    struct CachedGlyph {
        var uv: SIMD4<Float>
        var color: Bool
    }

    /// One new glyph to blit from a ring-slot staging texture into the matching atlas.
    struct Upload {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var destX: Int
        var destY: Int
        var stagingX: Int = 0
        var stagingY: Int = 0
        var uv: SIMD4<Float>
        var color: Bool
    }

    private struct Packer {
        var x = 0
        var y = 0
        var rowHeight = 0

        mutating func reset() {
            x = 0
            y = 0
            rowHeight = 0
        }

        mutating func place(width: Int, height: Int, side: Int) -> (x: Int, y: Int)? {
            if width > side || height > side { return nil }
            if x + width > side {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            if y + height > side { return nil }
            let origin = (x, y)
            x += width
            rowHeight = max(rowHeight, height)
            return origin
        }
    }

    init?(device: MTLDevice, side: Int = SSHTerminalGlyphAtlas.side) {
        let atlasSide = max(1, side)
        self.device = device
        self.side = atlasSide
        guard let textTexture = Self.makeTexture(
            device: device, pixelFormat: .r8Unorm, width: atlasSide, height: atlasSide
        ), let placeholder = Self.makeTexture(
            device: device, pixelFormat: .rgba8Unorm, width: 1, height: 1
        ) else { return nil }
        self.textTexture = textTexture
        self.colorTexture = placeholder
    }

    private static func makeTexture(
        device: MTLDevice, pixelFormat: MTLPixelFormat, width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    @discardableResult
    private func ensureColorAtlas() -> Bool {
        if colorAtlasReady { return true }
        guard let texture = Self.makeTexture(
            device: device, pixelFormat: .rgba8Unorm, width: side, height: side
        ) else { return false }
        colorTexture = texture
        colorAtlasReady = true
        return true
    }

    func resetPacking() {
        map.removeAll(keepingCapacity: true)
        textPack.reset()
        colorPack.reset()
    }

    func key(cell: SSHTerminalCell, face: UInt8) -> GlyphKey {
        GlyphKey(face: face, scalar: cell.cluster == nil ? cell.scalar : 0, cluster: cell.cluster ?? "")
    }

    func cached(_ key: GlyphKey) -> CachedGlyph? { map[key] }

    /// Place and rasterize a glyph the map does not yet have. Nil if it cannot
    /// fit in remaining space (caller may reset packing and try the whole frame).
    func place(
        cell: SSHTerminalCell,
        face: UInt8,
        font: UIFont,
        cellSize: CGSize,
        scale: CGFloat
    ) -> Upload? {
        let key = key(cell: cell, face: face)
        let columns = max(1, cell.width)
        let pixelWidth = max(1, Int(ceil(cellSize.width * CGFloat(columns) * scale)))
        let pixelHeight = max(1, Int(ceil(cellSize.height * scale)))
        guard let glyph = Self.rasterizeGlyph(
            text: cell.displayText, font: font,
            width: pixelWidth, height: pixelHeight,
            cellSize: cellSize, columns: columns, scale: scale
        ) else { return nil }
        let origin: (x: Int, y: Int)?
        if glyph.color {
            guard ensureColorAtlas() else { return nil }
            origin = colorPack.place(width: pixelWidth, height: pixelHeight, side: side)
        } else {
            origin = textPack.place(width: pixelWidth, height: pixelHeight, side: side)
        }
        guard let origin else { return nil }
        let s = Float(side)
        let uv = SIMD4<Float>(
            Float(origin.x) / s, Float(origin.y) / s,
            Float(origin.x + pixelWidth) / s, Float(origin.y + pixelHeight) / s
        )
        map[key] = CachedGlyph(uv: uv, color: glyph.color)
        let bytes = glyph.color ? glyph.bytes : Self.coverage(fromBGRA: glyph.bytes)
        return Upload(
            bytes: bytes, width: pixelWidth, height: pixelHeight,
            destX: origin.x, destY: origin.y, uv: uv, color: glyph.color
        )
    }

    private static func coverage(fromBGRA bytes: [UInt8]) -> [UInt8] {
        let pixels = bytes.count / 4
        var out = [UInt8](repeating: 0, count: pixels)
        var i = 0
        while i < pixels {
            out[i] = bytes[i * 4 + 3]
            i += 1
        }
        return out
    }

    /// White coverage at device scale, or native color for remaining emoji.
    /// Covered glyphs and cascade fallbacks (PingFang, Menlo, STIX, box-drawing)
    /// still draw at the cell origin and clip. Only a text-presentation
    /// substitute or a remaining color-emoji run may scale-to-fit. Each glyph
    /// is Core Text-drawn once.
    static func rasterize(
        text: String, font: UIFont,
        width: Int, height: Int,
        cellSize: CGSize, columns: Int, scale: CGFloat
    ) -> [UInt8]? {
        rasterizeGlyph(
            text: text, font: font, width: width, height: height,
            cellSize: cellSize, columns: columns, scale: scale
        )?.bytes
    }

    struct RasterizedGlyph {
        var bytes: [UInt8]
        var color: Bool
    }

    static func rasterizeGlyph(
        text: String, font: UIFont,
        width: Int, height: Int,
        cellSize: CGSize, columns: Int, scale: CGFloat
    ) -> RasterizedGlyph? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let points = CGSize(width: cellSize.width * CGFloat(columns), height: cellSize.height)
        let plan = planDraw(text: text, font: font, columns: columns)
        let area = CGRect(origin: .zero, size: points)
        var attributes: [NSAttributedString.Key: Any] = [.font: plan.font]
        if !plan.color {
            attributes[.foregroundColor] = UIColor.white
        }
        let image: UIImage
        if plan.constrain {
            image = rasterizeConstrained(
                text: plan.text, attributes: attributes,
                area: area, scale: scale, format: format
            )
        } else {
            image = UIGraphicsImageRenderer(size: points, format: format).image { ctx in
                ctx.cgContext.clip(to: area)
                (plan.text as NSString).draw(at: area.origin, withAttributes: attributes)
            }
        }
        guard let bytes = rgbaBytes(image, width: width, height: height) else { return nil }
        return RasterizedGlyph(bytes: bytes, color: plan.color)
    }

    /// Width-1 clusters that ask for emoji (U+FE0F) stay on the color-emoji
    /// path and scale to fit the cell. Bare and U+FE0E clusters whose only
    /// remaining scalar is one base use text presentation so glyphs such as
    /// U+23FA keep the whole record mark. Multi-scalar clusters keep their
    /// bytes and may only scale if they are still emoji. Cascade box-drawing,
    /// blocks, and CJK never constrain.
    private static func planDraw(
        text: String, font: UIFont, columns: Int
    ) -> (text: String, font: UIFont, constrain: Bool, color: Bool) {
        if sshTerminalFontCovers(font, text) {
            return (text, font, false, false)
        }
        let emoji = resolvedFontLooksLikeColorEmoji(text: text, font: font)
        guard emoji else { return (text, font, false, false) }
        let wantsEmoji = text.unicodeScalars.contains { $0.value == 0xFE0F }
        let bases = Array(text.unicodeScalars.filter { $0.value != 0xFE0E && $0.value != 0xFE0F })
        if columns == 1, bases.count == 1, !wantsEmoji {
            let base = String(bases[0])
            if let symbols = UIFont(name: "AppleSymbols", size: font.pointSize),
               sshTerminalFontCovers(symbols, base) {
                return (base, symbols, true, false)
            }
            return (base + "\u{FE0E}", font, true, false)
        }
        return (text, font, true, true)
    }

    private static func resolvedFontLooksLikeColorEmoji(text: String, font: UIFont) -> Bool {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else {
            return font.fontName.lowercased().contains("emoji")
        }
        let attrs = CTRunGetAttributes(run) as NSDictionary
        if let runFont = attrs[kCTFontAttributeName] as? UIFont {
            return runFont.fontName.lowercased().contains("emoji")
        }
        if let runFont = attrs[kCTFontAttributeName] {
            return String(describing: runFont).lowercased().contains("emoji")
        }
        return false
    }

    /// One Core Text draw into an oversized canvas, then a bitmap blit into the
    /// cell. Scale-to-fit is a blit, not a second text draw.
    private static func rasterizeConstrained(
        text: String,
        attributes: [NSAttributedString.Key: Any],
        area: CGRect,
        scale: CGFloat,
        format: UIGraphicsImageRendererFormat
    ) -> UIImage {
        let canvas = CGSize(
            width: max(area.width * 3, area.width + 1),
            height: max(area.height * 2, area.height + 1)
        )
        let loose = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }
        return UIGraphicsImageRenderer(size: area.size, format: format).image { ctx in
            ctx.cgContext.clip(to: area)
            guard let ink = inkBounds(of: loose, scale: scale) else { return }
            let fits = ink.minX >= -0.5 && ink.minY >= -0.5
                && ink.maxX <= area.width + 0.5 && ink.maxY <= area.height + 0.5
            if fits {
                loose.draw(at: .zero)
                return
            }
            let pad = 2 / max(scale, 1)
            let avail = CGRect(
                x: pad, y: pad,
                width: max(area.width - 2 * pad, pad),
                height: max(area.height - 2 * pad, pad)
            )
            let s = min(1, avail.width / max(ink.width, 0.001), avail.height / max(ink.height, 0.001))
            let fitted = CGSize(width: ink.width * s, height: ink.height * s)
            let tx = avail.minX + (avail.width - fitted.width) / 2 - ink.minX * s
            let ty = avail.minY + (avail.height - fitted.height) / 2 - ink.minY * s
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: tx, y: ty)
            ctx.cgContext.scaleBy(x: s, y: s)
            loose.draw(at: .zero)
            ctx.cgContext.restoreGState()
        }
    }

    private static func inkBounds(of image: UIImage, scale: CGFloat) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width, h = cgImage.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let bitmap = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                if bytes[(y * w + x) * 4 + 3] > 8 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    private static func rgbaBytes(_ image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let bitmap = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }
}

private func sshTerminalFontCovers(_ font: UIFont, _ text: String) -> Bool {
    let units = Array(text.utf16)
    guard !units.isEmpty else { return true }
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
}

/// Capped exponential back-off for a texture allocation Metal refused. Under
/// memory pressure a retry is another full-size allocation that fails again, so
/// an image that cannot be built waits 1, 2, 4 ... 64 frames instead of asking
/// every drawing frame.
struct SSHTerminalKittyTextureBackoff {
    /// Longest wait between attempts, about a second at frame rate.
    static let maxSkipFrames = 64

    /// Image generation this back-off belongs to. A retransmission of the same ID
    /// brings a new generation, which starts over.
    var generation: UInt64
    /// Consecutive failed allocations.
    private(set) var failures = 0
    /// First frame this generation may be tried again on.
    private(set) var retryTick: UInt64 = 0

    init(generation: UInt64) {
        self.generation = generation
    }

    /// Frames skipped after this many consecutive failures.
    static func skipFrames(afterFailures failures: Int) -> Int {
        guard failures > 0 else { return 0 }
        return min(maxSkipFrames, 1 << min(failures - 1, 6))
    }

    /// Record a failure on `frameTick` and schedule the next attempt.
    mutating func recordFailure(frameTick: UInt64) {
        failures += 1
        // Waiting N frames means N frames go by before the next attempt, so the
        // attempt itself lands on frameTick + N + 1.
        retryTick = frameTick &+ UInt64(Self.skipFrames(afterFailures: failures)) &+ 1
    }
}

/// Kitty image pixels, uploaded once per image generation. The generation stamp
/// changes on every add or replace of an image ID (including animation frames),
/// so a cached texture can never show stale pixels; a dimension comparison
/// would miss a same-sized retransmission. Entries leave when the image leaves
/// libghostty's store, and the budget below bounds the GPU memory a store full of
/// images can claim.
final class SSHTerminalKittyTextureCache {
    private struct Entry {
        let generation: UInt64
        let texture: MTLTexture
        /// What the GPU actually allocated. Gray and gray-alpha arrive expanded
        /// to RGBA, so this is not derivable from the stored format.
        let byteCount: Int
        /// Frame this entry was last drawn in; an entry drawn this frame is never
        /// evicted this frame.
        var lastUsed: UInt64
    }

    /// Texture bytes held here, sized from what libghostty's store can produce
    /// rather than from the store's own 64 MB. Only RGB and RGBA reach storage, so
    /// a screen's pixels cost at most four thirds of their stored bytes as RGBA,
    /// and the main and alternate screens together can hold the full store twice:
    /// 64 MB x 4/3 x 2, about 171 MB. Sizing it any lower would evict images the
    /// same frame draws and re-upload them on every redraw.
    static let limitBytes = SSHTerminalKittyGraphics.imageStorageLimitBytes / 3 * 8
    /// Where eviction stops (three quarters of the budget), so one frame that
    /// needs room pays for one eviction pass instead of one per upload.
    private var lowWaterBytes: Int { max(1, limit / 4 * 3) }

    private let limit: Int
    private var entries: [UInt32: Entry] = [:]
    /// Generations this cache knows can never fit the budget, the only refusal
    /// that is a property of the image rather than of this frame. A retransmission
    /// brings a new generation, and a store change clears the memo.
    private var unfittable: [UInt32: UInt64] = [:]
    /// Images whose upload failed transiently in a frame (the payload is not
    /// resident yet, no store handle, or the budget is momentarily full). They are
    /// skipped for the rest of that frame and retried on a later one.
    private var retriedFrame: [UInt32: UInt64] = [:]
    /// Images Metal refused to allocate a texture for, per ID and generation.
    private var backoff: [UInt32: SSHTerminalKittyTextureBackoff] = [:]
    /// Metal allocation for one texture. A test substitutes an allocator that
    /// fails: the only way to reach the memory-pressure path on a simulator.
    private let allocate: (MTLDevice, MTLTextureDescriptor) -> MTLTexture?
    /// Render pass this cache is serving; bumped by `beginFrame`.
    private var frameTick: UInt64 = 0
    /// Frame that already paid for an eviction pass.
    private var evictedFrameTick: UInt64 = .max
    private(set) var totalBytes = 0
    /// Texture creations, for tests and the perf bench: steady-state frames must
    /// not add to this. A texture the budget then refuses still counts.
    private(set) var uploadCount = 0
    /// Images dropped for budget or deletion, for tests: a frame past the budget
    /// must skip an image, never leak one.
    private(set) var evictionCount = 0
    var count: Int { entries.count }

    init(
        limit: Int = SSHTerminalKittyTextureCache.limitBytes,
        allocate: @escaping (MTLDevice, MTLTextureDescriptor) -> MTLTexture? = {
            $0.makeTexture(descriptor: $1)
        }
    ) {
        self.limit = max(1, limit)
        self.allocate = allocate
    }

    /// Start a render pass. Entries touched after this are off limits to eviction
    /// until the next pass.
    func beginFrame() {
        frameTick &+= 1
    }

    /// The texture for this image, uploading it the first time this generation is
    /// seen. Nil when there is no store to read this frame, the payload is not
    /// resident yet, the image does not fit the budget, or Metal refused the
    /// allocation (then retried on a doubling back-off, not every frame).
    func texture(
        for image: SSHTerminalKittyImage,
        graphics: GhosttyKittyGraphics?,
        device: MTLDevice
    ) -> MTLTexture? {
        guard image.width > 0, image.height > 0,
              image.width <= 16384, image.height <= 16384 else { return nil }
        let (pixels, overflowed) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflowed else { return nil }
        let (estimated, estimateOverflowed) = pixels.multipliedReportingOverflow(by: 4)
        // A picture whose texture could never fit is refused for this generation
        // before Metal is asked for it.
        guard !estimateOverflowed, estimated <= limit else {
            unfittable[image.id] = image.generation
            return nil
        }
        if var entry = entries[image.id] {
            if entry.generation == image.generation {
                entry.lastUsed = frameTick
                entries[image.id] = entry
                return entry.texture
            }
            entries[image.id] = nil
            totalBytes -= entry.byteCount
        }
        if unfittable[image.id] == image.generation { return nil }
        if retriedFrame[image.id] == frameTick { return nil }
        if let wait = backoff[image.id], wait.generation == image.generation,
           frameTick < wait.retryTick { return nil }
        // A held frame has no store to read, and the payload may simply not be
        // resident yet: both wait for a later frame instead of failing for good.
        guard let graphics, let payload = image.resolvePixels(graphics) else {
            retriedFrame[image.id] = frameTick
            return nil
        }
        // Room first, allocation second: a texture the budget then refused was a
        // full-size allocation spent and thrown away. The budget is full for now,
        // not forever: a later frame evicts what it no longer draws.
        guard makeRoom(for: estimated) else {
            retriedFrame[image.id] = frameTick
            return nil
        }
        guard let texture = makeTexture(device: device, image: image, payload: payload) else {
            retriedFrame[image.id] = frameTick
            var wait = backoff[image.id].flatMap {
                $0.generation == image.generation ? $0 : nil
            } ?? SSHTerminalKittyTextureBackoff(generation: image.generation)
            wait.recordFailure(frameTick: frameTick)
            backoff[image.id] = wait
            return nil
        }
        uploadCount += 1
        backoff[image.id] = nil
        // What Metal reports can be zero where the driver does not track it (the
        // simulator does), so the pixel bytes are the floor and the budget still
        // bounds what is held.
        let allocated = max(texture.allocatedSize, estimated)
        guard allocated <= limit else {
            unfittable[image.id] = image.generation
            return nil
        }
        // A driver may pad the allocation past the pixel estimate; the earlier
        // `makeRoom` already covers an exact match, so this only evicts for the
        // difference.
        guard makeRoom(for: allocated) else {
            retriedFrame[image.id] = frameTick
            return nil
        }
        entries[image.id] = Entry(
            generation: image.generation, texture: texture, byteCount: allocated,
            lastUsed: frameTick
        )
        totalBytes += allocated
        return texture
    }

    /// Make room for one texture by evicting images this frame did not draw, down
    /// to the low-water mark, at most once per frame.
    private func makeRoom(for allocated: Int) -> Bool {
        if totalBytes + allocated <= limit { return true }
        guard evictedFrameTick != frameTick else { return false }
        evictedFrameTick = frameTick
        let stale = entries
            .filter { $0.value.lastUsed < frameTick }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (id, entry) in stale {
            guard totalBytes + allocated > lowWaterBytes else { break }
            entries[id] = nil
            totalBytes -= entry.byteCount
            evictionCount += 1
        }
        return totalBytes + allocated <= limit
    }

    /// Drop every image libghostty no longer stores. An image whose placements
    /// scrolled out of the viewport, or whose screen is not the active one, is
    /// still stored, so its texture stays. A store change is also what clears the
    /// memo of images that could never fit.
    func retain(only stored: Set<UInt32>) {
        unfittable.removeAll(keepingCapacity: true)
        var evicted = [UInt32]()
        for (id, entry) in entries where !stored.contains(id) {
            totalBytes -= entry.byteCount
            evicted.append(id)
        }
        for id in evicted {
            entries[id] = nil
            evictionCount += 1
        }
        for id in Array(retriedFrame.keys) where !stored.contains(id) {
            retriedFrame.removeValue(forKey: id)
        }
        // Only the images that left the store. A host that keeps transmitting
        // moves the store generation on every picture, so clearing every back-off
        // here would put a refused image back on the every-frame retry; an image
        // retransmitted under the same ID moves its own generation instead, which
        // resets its wait.
        for id in Array(backoff.keys) where !stored.contains(id) {
            backoff.removeValue(forKey: id)
        }
    }

    private func makeTexture(
        device: MTLDevice, image: SSHTerminalKittyImage, payload: SSHTerminalKittyPixels
    ) -> MTLTexture? {
        // Only RGB and RGBA reach storage: the protocol parses f=24, f=32 and PNG
        // (f=100), which libghostty decodes to RGBA.
        guard image.format == .rgba || image.format == .rgb else { return nil }
        let (pixels, pixelsOverflowed) = image.width.multipliedReportingOverflow(by: image.height)
        guard !pixelsOverflowed,
              payload.byteCount >= pixels * image.format.bytesPerPixel else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = allocate(device, descriptor) else { return nil }
        let source = payload.pointer
        let bytesPerRow = image.width * 4
        if image.format == .rgba {
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                withBytes: source, bytesPerRow: bytesPerRow
            )
            return texture
        }
        // Metal has no 3-channel format, so RGB expands to RGBA at upload. One row
        // is expanded at a time into a reused buffer: a full-size expansion is up
        // to 85 MB of temporary that can itself fail (and trap) under the memory
        // pressure this path runs in. Same total copy, O(width) bytes.
        let sourceBytesPerRow = image.width * 3
        // Alpha never changes across rows, so it is filled once here.
        var row = [UInt8](repeating: 0xFF, count: bytesPerRow)
        return row.withUnsafeMutableBufferPointer { buffer -> MTLTexture? in
            guard let expanded = buffer.baseAddress else { return nil }
            for y in 0..<image.height {
                let rowStart = source + y * sourceBytesPerRow
                for x in 0..<image.width {
                    expanded[x * 4] = rowStart[x * 3]
                    expanded[x * 4 + 1] = rowStart[x * 3 + 1]
                    expanded[x * 4 + 2] = rowStart[x * 3 + 2]
                }
                texture.replace(
                    region: MTLRegionMake2D(0, y, image.width, 1), mipmapLevel: 0,
                    withBytes: expanded, bytesPerRow: bytesPerRow
                )
            }
            return texture
        }
    }
}

/// Instanced cell quads. Three instance-buffer slots; a slot is not rewritten
/// until its command buffer completion handler runs.
final class SSHTerminalMetalRenderer: @unchecked Sendable {
    static let ringSize = 3
    static let glyphFlag: UInt32 = 1
    static let colorGlyphFlag: UInt32 = 2

    struct CellInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var uv: SIMD4<Float>
        var flags: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
        var pad2: UInt32 = 0
    }

    struct Uniforms {
        var viewportX: Float
        var viewportY: Float
        /// Whole pixels the grid moves up: a history scroll between rows.
        var shiftY: Float = 0
        var pad: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let solid: MTLRenderPipelineState
    private let overlay: MTLRenderPipelineState
    private let glyph: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let atlas: SSHTerminalGlyphAtlas
    /// Kitty image textures, keyed by image ID and generation. The budget is a
    /// parameter so a test can hold the cache to a size the device would reach.
    private let kittyTextures: SSHTerminalKittyTextureCache
    /// Store generation the texture cache was last pruned against.
    private var evictedKittyGeneration: UInt64 = .max
    private let lock = NSLock()
    private var slots: [Slot]
    private var faces = [UInt8: UIFont]()
    private var rowCache: [RowInstances] = []
    var metrics: SSHTerminalCellMetrics
    var scale: CGFloat

    private struct Slot {
        var buffer: MTLBuffer
        var capacity: Int
        var inFlight: Bool
        /// Shared staging for this slot's glyph blits. CPU-written only while
        /// the slot is free, then sampled by that same command buffer.
        var textStaging: MTLTexture?
        var colorStaging: MTLTexture?
    }

    private struct RowInstances {
        var backgrounds: [CellInstance] = []
        var glyphs: [CellInstance] = []
        var overlays: [CellInstance] = []
    }

    enum RendererError: Error {
        case noBuffer
        case noAtlas
    }

    init(
        pipeline: SSHTerminalMetalPipeline,
        metrics: SSHTerminalCellMetrics,
        scale: CGFloat,
        atlasSide: Int = SSHTerminalGlyphAtlas.side,
        kittyTextureLimit: Int = SSHTerminalKittyTextureCache.limitBytes,
        kittyTextureAllocate: @escaping (MTLDevice, MTLTextureDescriptor) -> MTLTexture? = {
            $0.makeTexture(descriptor: $1)
        }
    ) throws {
        self.device = pipeline.device
        self.queue = pipeline.queue
        self.solid = pipeline.solid
        self.overlay = pipeline.overlay
        self.glyph = pipeline.glyph
        self.imagePipeline = pipeline.image
        self.metrics = metrics
        self.scale = max(scale, 1)
        self.kittyTextures = SSHTerminalKittyTextureCache(
            limit: kittyTextureLimit, allocate: kittyTextureAllocate
        )
        guard let atlas = SSHTerminalGlyphAtlas(device: pipeline.device, side: atlasSide) else {
            throw RendererError.noAtlas
        }
        self.atlas = atlas
        var built: [Slot] = []
        built.reserveCapacity(Self.ringSize)
        let initial = 256
        for _ in 0..<Self.ringSize {
            guard let buffer = device.makeBuffer(
                length: initial * MemoryLayout<CellInstance>.stride,
                options: .storageModeShared
            ) else { throw RendererError.noBuffer }
            built.append(Slot(
                buffer: buffer, capacity: initial, inFlight: false,
                textStaging: nil, colorStaging: nil
            ))
        }
        self.slots = built
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.filter(\.inFlight).count
    }

    var freeSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.filter { !$0.inFlight }.count
    }

    /// Images currently holding a texture, how many texture uploads have
    /// happened in total, and how many were dropped for budget or deletion. The
    /// bench and tests use these to prove that a frame in the steady state
    /// copies no pixels.
    var cachedImageCount: Int { kittyTextures.count }
    var imageUploadCount: Int { kittyTextures.uploadCount }
    var imageEvictionCount: Int { kittyTextures.evictionCount }
    var cachedImageBytes: Int { kittyTextures.totalBytes }

    func setMetrics(_ metrics: SSHTerminalCellMetrics, scale: CGFloat) {
        let scale = max(scale, 1)
        guard metrics.cellSize != self.metrics.cellSize
            || metrics.font.fontName != self.metrics.font.fontName
            || metrics.font.pointSize != self.metrics.font.pointSize
            || scale != self.scale else { return }
        self.metrics = metrics
        self.scale = scale
        faces.removeAll()
        // Next encode re-packs and blits every glyph; prior command buffers
        // keep sampling the old UVs until they complete.
        atlas.resetPacking()
        invalidateRowCache()
    }

    private func invalidateRowCache() {
        rowCache.removeAll(keepingCapacity: true)
    }

    /// `shiftPixels` moves every row, cursor included, up by that many whole
    /// pixels. Only the uniform changes, so a shift-only frame reuses every
    /// cached row.
    func encode(
        frame: SSHTerminalFrame,
        cursorColor: SIMD4<Float>,
        drawable: CAMetalDrawable,
        fullRebuild: Bool = true,
        shiftPixels: Int = 0
    ) -> SSHTerminalMetalFrameCost {
        encode(
            frame: frame,
            cursorColor: cursorColor,
            target: drawable.texture,
            drawable: drawable,
            waitUntilCompleted: false,
            fullRebuild: fullRebuild,
            shiftPixels: shiftPixels
        )
    }

    func encodeOffscreen(
        frame: SSHTerminalFrame,
        cursorColor: SIMD4<Float>,
        texture: MTLTexture,
        waitUntilCompleted: Bool,
        fullRebuild: Bool = true,
        shiftPixels: Int = 0
    ) -> SSHTerminalMetalFrameCost {
        encode(
            frame: frame,
            cursorColor: cursorColor,
            target: texture,
            drawable: nil,
            waitUntilCompleted: waitUntilCompleted,
            fullRebuild: fullRebuild,
            shiftPixels: shiftPixels
        )
    }

    func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(
        frame: SSHTerminalFrame,
        cursorColor: SIMD4<Float>,
        target: MTLTexture,
        drawable: CAMetalDrawable?,
        waitUntilCompleted: Bool,
        fullRebuild: Bool,
        shiftPixels: Int
    ) -> SSHTerminalMetalFrameCost {
        let failed = SSHTerminalMetalFrameCost(
            encodeNanos: 0, submitted: false, completed: false, status: .error,
            errorDescription: nil, miss: .transient
        )
        // place() publishes UVs before the blit commits. On every path that
        // packed new glyphs and does not commit, drop those keys so a later
        // frame cannot sample blank atlas texels. In-flight buffers still
        // sample old texels; later blits on this queue wait for those reads.
        func abort(
            slot: Int? = nil,
            uploads: [SSHTerminalGlyphAtlas.Upload] = [],
            miss: SSHTerminalMetalEncodeMiss,
            reason: String
        ) -> SSHTerminalMetalFrameCost {
            if let slot { releaseSlot(slot) }
            if !uploads.isEmpty {
                atlas.resetPacking()
                invalidateRowCache()
            }
            var cost = failed
            cost.miss = miss
            cost.errorDescription = reason
            return cost
        }
        let encodeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let packed = pack(frame: frame, cursorColor: cursorColor, fullRebuild: fullRebuild) else {
            return abort(miss: .deterministic, reason: "glyph atlas cannot fit this frame")
        }
        let uploadsBefore = kittyTextures.uploadCount
        let images = packImages(
            frame.kitty,
            graphics: frame.kittyGraphics,
            cellW: Float(metrics.cellSize.width * scale),
            cellH: Float(metrics.cellSize.height * scale)
        )
        let imageUploads = kittyTextures.uploadCount - uploadsBefore
        var instances = packed.all
        if !images.instances.isEmpty {
            instances.append(contentsOf: images.instances)
        }
        guard let slotIndex = bind(instances) else {
            return abort(
                uploads: packed.uploads, miss: .transient, reason: "no free Metal instance slot"
            )
        }
        var uploads = packed.uploads
        let staging: StagingPair
        if uploads.isEmpty {
            staging = StagingPair(text: nil, color: nil)
        } else if let prepared = prepareStaging(slot: slotIndex, uploads: &uploads) {
            staging = prepared
        } else {
            return abort(
                slot: slotIndex, uploads: uploads,
                miss: .deterministic, reason: "no glyph staging texture"
            )
        }
        markInFlight(slotIndex)
        guard let commandBuffer = queue.makeCommandBuffer() else {
            return abort(
                slot: slotIndex, uploads: uploads,
                miss: .transient, reason: "makeCommandBuffer returned nil"
            )
        }
        if !uploads.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                return abort(
                    slot: slotIndex, uploads: uploads,
                    miss: .transient, reason: "makeBlitCommandEncoder returned nil"
                )
            }
            // Same queue as prior atlas samples: the blit waits for those reads,
            // then this frame's draw samples the new texels.
            for upload in uploads {
                let source = upload.color ? staging.color : staging.text
                let destination = upload.color ? atlas.colorTexture : atlas.textTexture
                guard let source else { continue }
                blit.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: upload.stagingX, y: upload.stagingY, z: 0),
                    sourceSize: MTLSize(width: upload.width, height: upload.height, depth: 1),
                    to: destination,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: upload.destX, y: upload.destY, z: 0)
                )
            }
            blit.endEncoding()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(frame.background.r) / 255,
            Double(frame.background.g) / 255,
            Double(frame.background.b) / 255,
            1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return abort(
                slot: slotIndex, uploads: uploads,
                miss: .transient, reason: "makeRenderCommandEncoder returned nil"
            )
        }
        let uniforms = Uniforms(
            viewportX: Float(target.width), viewportY: Float(target.height), shiftY: Float(shiftPixels)
        )
        let backgrounds = packed.backgrounds
        let glyphs = packed.glyphs
        let overlays = packed.overlays
        let stride = MemoryLayout<CellInstance>.stride
        let imageBase = backgrounds.count + glyphs.count + overlays.count
        // One pipeline for every image; one draw per image per layer, so the
        // layer order below is the whole z-index implementation.
        func draw(
            _ state: MTLRenderPipelineState,
            instanceOffset: Int,
            count: Int,
            texture: MTLTexture? = nil
        ) {
            guard count > 0 else { return }
            encoder.setRenderPipelineState(state)
            encoder.setVertexBuffer(
                slots[slotIndex].buffer, offset: instanceOffset * stride, index: 0
            )
            withUnsafeBytes(of: uniforms) { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(base, length: bytes.count, index: 1)
            }
            if let texture { encoder.setFragmentTexture(texture, index: 0) }
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count
            )
        }
        for group in images.groups where group.layer == .belowBackground {
            draw(
                imagePipeline, instanceOffset: imageBase + group.instances.lowerBound,
                count: group.instances.count, texture: group.texture
            )
        }
        draw(solid, instanceOffset: 0, count: backgrounds.count)
        for group in images.groups where group.layer == .belowText {
            draw(
                imagePipeline, instanceOffset: imageBase + group.instances.lowerBound,
                count: group.instances.count, texture: group.texture
            )
        }
        if !glyphs.isEmpty {
            encoder.setRenderPipelineState(glyph)
            encoder.setVertexBuffer(
                slots[slotIndex].buffer,
                offset: backgrounds.count * stride,
                index: 0
            )
            withUnsafeBytes(of: uniforms) { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(base, length: bytes.count, index: 1)
            }
            encoder.setFragmentTexture(atlas.textTexture, index: 0)
            encoder.setFragmentTexture(atlas.colorTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        draw(
            overlay, instanceOffset: backgrounds.count + glyphs.count, count: overlays.count
        )
        for group in images.groups where group.layer == .aboveText {
            draw(
                imagePipeline, instanceOffset: imageBase + group.instances.lowerBound,
                count: group.instances.count, texture: group.texture
            )
        }
        encoder.endEncoding()
        let encodeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - encodeStart
        if let drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.addCompletedHandler { [weak self] finished in
            self?.releaseSlot(slotIndex)
            _ = finished
        }
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
            return SSHTerminalMetalFrameCost(
                encodeNanos: encodeNanos,
                submitted: true,
                completed: commandBuffer.status == .completed,
                status: commandBuffer.status,
                errorDescription: commandBuffer.error.map(String.init(describing:)),
                rebuiltRowCount: packed.rebuiltRowCount,
                reusedRowCount: packed.reusedRowCount,
                imagePlacementCount: images.instances.count,
                imageUploadCount: imageUploads
            )
        }
        return SSHTerminalMetalFrameCost(
            encodeNanos: encodeNanos,
            submitted: true,
            completed: false,
            status: commandBuffer.status,
            errorDescription: nil,
            rebuiltRowCount: packed.rebuiltRowCount,
            reusedRowCount: packed.reusedRowCount,
            imagePlacementCount: images.instances.count,
            imageUploadCount: imageUploads
        )
    }

    private struct PackedInstances {
        var backgrounds: [CellInstance]
        var glyphs: [CellInstance]
        var overlays: [CellInstance]
        var uploads: [SSHTerminalGlyphAtlas.Upload]
        var rebuiltRowCount: Int
        var reusedRowCount: Int
        var all: [CellInstance] { backgrounds + glyphs + overlays }
    }

    private func pack(
        frame: SSHTerminalFrame, cursorColor: SIMD4<Float>, fullRebuild: Bool
    ) -> PackedInstances? {
        if let packed = packOnce(frame: frame, cursorColor: cursorColor, fullRebuild: fullRebuild) {
            return packed
        }
        atlas.resetPacking()
        invalidateRowCache()
        if let packed = packOnce(frame: frame, cursorColor: cursorColor, fullRebuild: true) {
            return packed
        }
        // Second pack still missed: drop keys place() already inserted so a
        // later frame cannot treat un-uploaded texels as resident.
        atlas.resetPacking()
        invalidateRowCache()
        return nil
    }

    private func packOnce(
        frame: SSHTerminalFrame, cursorColor: SIMD4<Float>, fullRebuild: Bool
    ) -> PackedInstances? {
        let cell = metrics.cellSize
        let scale = scale
        let cellW = Float(cell.width * scale)
        let cellH = Float(cell.height * scale)
        let rowCount = frame.rows.count
        var uploads = [SSHTerminalGlyphAtlas.Upload]()
        let rebuildAll = fullRebuild || rowCache.count != rowCount
        if rowCache.count != rowCount {
            rowCache = Array(repeating: RowInstances(), count: rowCount)
        }
        var dirty = IndexSet()
        if rebuildAll {
            dirty = IndexSet(integersIn: 0..<rowCount)
        } else {
            for y in frame.rebuiltRows where y >= 0 && y < rowCount {
                dirty.insert(y)
            }
        }
        let defaultBg = Self.rgba(frame.background)
        let cols = frame.rows.first?.count ?? 0
        var backgrounds = [CellInstance]()
        var glyphs = [CellInstance]()
        var overlays = [CellInstance]()
        backgrounds.reserveCapacity(max(1, rowCount * cols))
        glyphs.reserveCapacity(max(1, rowCount * cols))
        let appendNow = rebuildAll
        for y in dirty {
            guard let packed = packRow(
                y: y, row: frame.rows[y], defaultBg: defaultBg,
                cell: cell, cellW: cellW, cellH: cellH, uploads: &uploads
            ) else { return nil }
            rowCache[y] = packed
            if appendNow {
                backgrounds.append(contentsOf: packed.backgrounds)
                glyphs.append(contentsOf: packed.glyphs)
                overlays.append(contentsOf: packed.overlays)
            }
        }
        if !appendNow {
            for row in rowCache {
                backgrounds.append(contentsOf: row.backgrounds)
                glyphs.append(contentsOf: row.glyphs)
                overlays.append(contentsOf: row.overlays)
            }
        }
        if let cursor = cursorQuad(
            frame: frame, color: Self.premultiply(cursorColor), cellW: cellW, cellH: cellH
        ) {
            overlays.append(contentsOf: cursor)
        }
        return PackedInstances(
            backgrounds: backgrounds, glyphs: glyphs, overlays: overlays, uploads: uploads,
            rebuiltRowCount: dirty.count, reusedRowCount: max(0, rowCount - dirty.count)
        )
    }

    private struct ImageGroup {
        var layer: SSHTerminalKittyLayer
        /// Range in the image instance list, which follows the cell instances.
        var instances: Range<Int>
        var texture: MTLTexture
    }

    private struct ImagePacking {
        var instances: [CellInstance] = []
        var groups: [ImageGroup] = []
    }

    /// Distinct images one frame draws. Past this the frame draws nothing more: a
    /// host that sprays thousands of tiny images cannot turn one frame into
    /// thousands of draw calls and texture uploads.
    static let maxKittyImagesPerFrame = 256
    /// Placement quads one frame draws, which bounds the instance data too.
    static let maxKittyPlacementsPerFrame = 1024

    /// Place every visible Kitty placement as a cell-space quad, sampling its
    /// source rectangle. Pixels reach a texture only when an image generation
    /// changes (see `SSHTerminalKittyTextureCache`), and they are read from
    /// libghostty only then; a frame in the steady state appends instances and
    /// makes no per-image calls. The snapshot arrives sorted by (layer, image ID)
    /// with its images already indexed by ID, so one pass over the placements
    /// groups them exactly in draw order with no search per image. Textures are
    /// evicted only when libghostty dropped the image from its store.
    private func packImages(
        _ kitty: SSHTerminalKittySnapshot?,
        graphics: GhosttyKittyGraphics?,
        cellW: Float,
        cellH: Float
    ) -> ImagePacking {
        kittyTextures.beginFrame()
        guard let kitty else {
            // Nothing is stored on this screen. Cached textures stay: the other
            // screen's store may still hold them (an alternate-screen toggle),
            // and the byte budget bounds what is kept. A later generation stamp
            // that differs still evicts whatever really left the store.
            return ImagePacking()
        }
        // The store generation moves on any transmit, placement or delete. An
        // image that only scrolled out of view is still stored, so it keeps its
        // texture and scrolling back copies no pixels.
        if kitty.generation != evictedKittyGeneration {
            kittyTextures.retain(only: kitty.storedImageIDs)
            evictedKittyGeneration = kitty.generation
        }
        guard !kitty.placements.isEmpty, !kitty.images.isEmpty else { return ImagePacking() }
        // Placement geometry is in terminal pixels; the drawable's cells may be
        // a fraction of a pixel different after rounding.
        let scaleX = cellW / Float(max(1, kitty.cellWidth))
        let scaleY = cellH / Float(max(1, kitty.cellHeight))
        var packing = ImagePacking()
        packing.instances.reserveCapacity(min(kitty.placements.count, Self.maxKittyPlacementsPerFrame))
        var drawnImages = 0
        var index = 0
        while index < kitty.placements.count {
            let layer = kitty.placements[index].layer
            let imageID = kitty.placements[index].imageID
            var end = index + 1
            while end < kitty.placements.count,
                  kitty.placements[end].layer == layer,
                  kitty.placements[end].imageID == imageID {
                end += 1
            }
            // Every `continue` below still moves past this image's placements.
            defer { index = end }
            guard packing.instances.count < Self.maxKittyPlacementsPerFrame,
                  drawnImages < Self.maxKittyImagesPerFrame,
                  let image = kitty.imagesByID[imageID], image.width > 0, image.height > 0,
                  let texture = kittyTextures.texture(
                      for: image, graphics: graphics, device: device
                  ) else { continue }
            let width = Float(image.width)
            let height = Float(image.height)
            let start = packing.instances.count
            for placement in kitty.placements[index..<end] {
                guard packing.instances.count < Self.maxKittyPlacementsPerFrame else { break }
                let size = SIMD2<Float>(
                    Float(placement.pixelWidth) * scaleX, Float(placement.pixelHeight) * scaleY
                )
                guard size.x > 0, size.y > 0 else { continue }
                let origin = SIMD2<Float>(
                    Float(placement.viewportColumn) * cellW + Float(placement.xOffset) * scaleX,
                    Float(placement.viewportRow) * cellH + Float(placement.yOffset) * scaleY
                )
                let uv = SIMD4<Float>(
                    Float(placement.sourceX) / width, Float(placement.sourceY) / height,
                    Float(placement.sourceX + placement.sourceWidth) / width,
                    Float(placement.sourceY + placement.sourceHeight) / height
                )
                packing.instances.append(CellInstance(
                    origin: origin, size: size, color: SIMD4(1, 1, 1, 1), uv: uv, flags: 0
                ))
            }
            if packing.instances.count > start {
                packing.groups.append(ImageGroup(
                    layer: layer, instances: start..<packing.instances.count, texture: texture
                ))
                drawnImages += 1
            }
        }
        return packing
    }

    private func packRow(
        y: Int,
        row: [SSHTerminalCell],
        defaultBg: SIMD4<Float>,
        cell: CGSize,
        cellW: Float,
        cellH: Float,
        uploads: inout [SSHTerminalGlyphAtlas.Upload]
    ) -> RowInstances? {
        var packed = RowInstances()
        packed.backgrounds.reserveCapacity(row.count)
        packed.glyphs.reserveCapacity(row.count)
        for (x, item) in row.enumerated() {
            guard item.width > 0 else { continue }
            let origin = SIMD2<Float>(Float(x) * cellW, Float(y) * cellH)
            let size = SIMD2<Float>(Float(item.width) * cellW, cellH)
            let colors = Self.paintColors(item)
            if colors.bg != defaultBg {
                packed.backgrounds.append(
                    CellInstance(origin: origin, size: size, color: colors.bg, uv: .zero, flags: 0)
                )
            }
            // Invisible cells keep their background and draw nothing else,
            // matching the old painter's early return.
            guard !item.style.invisible else { continue }
            var fg = colors.fg
            if item.style.faint { fg = Self.premultiply(fg, alpha: 0.5) }
            if item.style.underline != 0 {
                let yOff = underlineY(scale: scale)
                packed.overlays.append(CellInstance(
                    origin: SIMD2(origin.x, origin.y + yOff.y),
                    size: SIMD2(size.x, yOff.h),
                    color: fg, uv: .zero, flags: 0
                ))
            }
            if item.style.strikethrough {
                packed.overlays.append(CellInstance(
                    origin: SIMD2(origin.x, origin.y + cellH * 0.5 - 1),
                    size: SIMD2(size.x, max(1, Float(scale))),
                    color: fg, uv: .zero, flags: 0
                ))
            }
            guard item.hasInk else { continue }
            let face = face(bold: item.style.bold, italic: item.style.italic, text: item)
            let key = atlas.key(cell: item, face: face.key)
            let uv: SIMD4<Float>
            var colorGlyph = false
            if let cached = atlas.cached(key) {
                uv = cached.uv
                colorGlyph = cached.color
            } else if let upload = atlas.place(
                cell: item, face: face.key, font: face.font,
                cellSize: cell, scale: scale
            ) {
                uploads.append(upload)
                uv = upload.uv
                colorGlyph = upload.color
            } else {
                return nil
            }
            var flags = Self.glyphFlag
            if colorGlyph { flags |= Self.colorGlyphFlag }
            packed.glyphs.append(
                CellInstance(origin: origin, size: size, color: fg, uv: uv, flags: flags)
            )
        }
        return packed
    }

    private struct StagingPair {
        var text: MTLTexture?
        var color: MTLTexture?
    }

    private func prepareStaging(
        slot: Int, uploads: inout [SSHTerminalGlyphAtlas.Upload]
    ) -> StagingPair? {
        // Same shelf as the atlas: a set of glyphs that packed into the atlas
        // packs into staging. Never exceed the device 2D cap (simulator Metal
        // validation is 8192; Apple GPUs in this app are 16384).
        let shelf = min(atlas.side, 8192)
        let textSize = layoutStaging(&uploads, color: false, shelf: shelf)
        let colorSize = layoutStaging(&uploads, color: true, shelf: shelf)
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(slot) else { return nil }
        let hasText = uploads.contains { !$0.color }
        let hasColor = uploads.contains { $0.color }
        let pair = StagingPair(
            text: hasText ? ensureStaging(
                existing: slots[slot].textStaging,
                width: textSize.width, height: textSize.height, color: false
            ) : nil,
            color: hasColor ? ensureStaging(
                existing: slots[slot].colorStaging,
                width: colorSize.width, height: colorSize.height, color: true
            ) : nil
        )
        if hasText { slots[slot].textStaging = pair.text }
        if hasColor { slots[slot].colorStaging = pair.color }
        if hasText && pair.text == nil { return nil }
        if hasColor && pair.color == nil { return nil }
        for upload in uploads {
            let staging = upload.color ? pair.color : pair.text
            guard let staging else { continue }
            upload.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                staging.replace(
                    region: MTLRegionMake2D(upload.stagingX, upload.stagingY, upload.width, upload.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: upload.color ? upload.width * 4 : upload.width
                )
            }
        }
        return pair
    }

    private func layoutStaging(
        _ uploads: inout [SSHTerminalGlyphAtlas.Upload], color: Bool, shelf: Int
    ) -> (width: Int, height: Int) {
        var x = 0, y = 0, rowHeight = 0, stagedWidth = 1, stagedHeight = 1
        for i in uploads.indices where uploads[i].color == color {
            if x + uploads[i].width > shelf {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            uploads[i].stagingX = x
            uploads[i].stagingY = y
            x += uploads[i].width
            rowHeight = max(rowHeight, uploads[i].height)
            stagedWidth = max(stagedWidth, x)
            stagedHeight = max(stagedHeight, y + rowHeight)
        }
        return (stagedWidth, stagedHeight)
    }

    private func ensureStaging(
        existing: MTLTexture?, width: Int, height: Int, color: Bool
    ) -> MTLTexture? {
        if let existing, existing.width >= width, existing.height >= height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: color ? .rgba8Unorm : .r8Unorm,
            width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func cursorQuad(
        frame: SSHTerminalFrame,
        color: SIMD4<Float>,
        cellW: Float,
        cellH: Float
    ) -> [CellInstance]? {
        guard frame.cursor.visible, frame.cursor.viewport_has_value else { return nil }
        let x = Float(frame.cursor.viewport_x) * cellW
        let y = Float(frame.cursor.viewport_y) * cellH
        let hair = max(1, Float(scale))
        switch frame.cursor.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
            return [CellInstance(origin: SIMD2(x, y), size: SIMD2(2 * hair, cellH), color: color, uv: .zero, flags: 0)]
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            return [CellInstance(
                origin: SIMD2(x, y + cellH - 2 * hair),
                size: SIMD2(cellW, 2 * hair),
                color: color, uv: .zero, flags: 0
            )]
        default:
            // Block / hollow: 1px outline, matching the old `stroke(inset 0.5)`.
            return [
                CellInstance(origin: SIMD2(x, y), size: SIMD2(cellW, hair), color: color, uv: .zero, flags: 0),
                CellInstance(origin: SIMD2(x, y + cellH - hair), size: SIMD2(cellW, hair), color: color, uv: .zero, flags: 0),
                CellInstance(origin: SIMD2(x, y), size: SIMD2(hair, cellH), color: color, uv: .zero, flags: 0),
                CellInstance(origin: SIMD2(x + cellW - hair, y), size: SIMD2(hair, cellH), color: color, uv: .zero, flags: 0),
            ]
        }
    }

    private func underlineY(scale: CGFloat) -> (y: Float, h: Float) {
        let font = metrics.font
        let position = CTFontGetUnderlinePosition(font as CTFont)
        let thickness = max(CGFloat(scale), CTFontGetUnderlineThickness(font as CTFont) * scale)
        let y = (font.ascender - CGFloat(position)) * scale
        return (Float(y), Float(thickness))
    }

    private func face(bold: Bool, italic: Bool, text: SSHTerminalCell) -> (key: UInt8, font: UIFont) {
        let key: UInt8 = (bold ? 1 : 0) | (italic ? 2 : 0)
        let styled: UIFont = {
            if let cached = faces[key] { return cached }
            let weighted = bold ? metrics.boldFont : metrics.font
            let value = italic
                ? weighted.fontDescriptor.withSymbolicTraits(.traitItalic)
                    .map { NerdFontSymbols.withFallback(UIFont(descriptor: $0, size: weighted.pointSize)) } ?? weighted
                : weighted
            faces[key] = value
            return value
        }()
        // SF Mono ignores cascade lists, so uncovered private-use icons use the
        // symbols face, matching the old CPU painter.
        if text.needsSymbols,
           !sshTerminalFontCovers(styled, text.displayText),
           let symbols = NerdFontSymbols.font(size: metrics.font.pointSize) {
            if let cached = faces[4] { return (4, cached) }
            faces[4] = symbols
            return (4, symbols)
        }
        return (key, styled)
    }

    private func bind(_ instances: [CellInstance]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = slots.firstIndex(where: { !$0.inFlight }) else { return nil }
        let needed = max(instances.count, 64)
        if needed > slots[index].capacity {
            guard let grown = device.makeBuffer(
                length: needed * MemoryLayout<CellInstance>.stride,
                options: .storageModeShared
            ) else { return nil }
            slots[index].buffer = grown
            slots[index].capacity = needed
        }
        if !instances.isEmpty {
            instances.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                slots[index].buffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        return index
    }

    private func markInFlight(_ index: Int) {
        lock.lock()
        if slots.indices.contains(index) {
            slots[index].inFlight = true
        }
        lock.unlock()
    }

    private func releaseSlot(_ index: Int) {
        lock.lock()
        if slots.indices.contains(index) {
            slots[index].inFlight = false
        }
        lock.unlock()
    }

    private static func paintColors(_ cell: SSHTerminalCell) -> (fg: SIMD4<Float>, bg: SIMD4<Float>) {
        let fg = cell.style.inverse ? cell.background : cell.foreground
        let bg = cell.style.inverse ? cell.foreground : cell.background
        return (rgba(fg), rgba(bg))
    }

    static func rgba(_ rgb: GhosttyColorRgb, alpha: Float = 1) -> SIMD4<Float> {
        premultiply(SIMD4(Float(rgb.r) / 255, Float(rgb.g) / 255, Float(rgb.b) / 255, 1), alpha: alpha)
    }

    static func premultiply(_ color: SIMD4<Float>, alpha: Float = 1) -> SIMD4<Float> {
        let a = color.w * alpha
        return SIMD4(color.x * a, color.y * a, color.z * a, a)
    }
}

extension SSHTerminalCell {
    var displayText: String {
        if let cluster { return cluster }
        guard scalar != 0, let unit = Unicode.Scalar(scalar) else { return " " }
        return String(unit)
    }

    var hasInk: Bool {
        if let cluster { return cluster.contains(where: { $0 != " " }) }
        return scalar != 0 && scalar != 32
    }

    var needsSymbols: Bool {
        if let cluster {
            return cluster.unicodeScalars.contains(where: NerdFontSymbols.isPrivateUse)
        }
        guard let unit = Unicode.Scalar(scalar) else { return false }
        return NerdFontSymbols.isPrivateUse(unit)
    }
}
