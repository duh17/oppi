import CoreText
import GhosttyVt
import Metal
import QuartzCore
import UIKit

/// Code Font / Code Text Size, with Nerd Font symbols as a fallback once
/// they are installed. A 12pt base is 13pt at 100%, the terminal's size
/// before it followed Code Text Size.
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
        let family = FontPreferences.codeFont
        let size = FontPreferences.codePointSize(baseSize: 12)
        return SSHTerminalCellMetrics(
            font: family.font(size: size, weight: .regular),
            boldFont: family.font(size: size, weight: .bold)
        )
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
}

/// Process-wide pipeline from the precompiled metallib. Built off the main
/// thread so first open does not stall on `makeRenderPipelineState`.
final class SSHTerminalMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let solid: MTLRenderPipelineState
    let overlay: MTLRenderPipelineState
    let glyph: MTLRenderPipelineState

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
        func pipeline(_ fragment: MTLFunction, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                let color = descriptor.colorAttachments[0]
                color?.isBlendingEnabled = true
                color?.sourceRGBBlendFactor = .one
                color?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color?.sourceAlphaBlendFactor = .one
                color?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw PipelineError.pipeline(String(describing: error))
            }
        }
        self.device = device
        self.queue = queue
        self.solid = try pipeline(solidFn, blending: false)
        self.overlay = try pipeline(solidFn, blending: true)
        self.glyph = try pipeline(glyphFn, blending: true)
    }
}

/// Core Text glyphs rasterized once at device scale, keyed by grapheme + face.
/// CPU packing only: new ink reaches the private atlas through a blit in the
/// same command buffer as the draw, so a later frame cannot CPU-write texels
/// an earlier buffer is still sampling.
final class SSHTerminalGlyphAtlas {
    static let side = 2048
    let texture: MTLTexture
    let side: Int
    private var map = [GlyphKey: SIMD4<Float>]()
    private var x = 0
    private var y = 0
    private var rowHeight = 0

    struct GlyphKey: Hashable {
        var face: UInt8
        var scalar: UInt32
        var cluster: String
    }

    /// One new glyph to blit from a ring-slot staging texture into `texture`.
    struct Upload {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var destX: Int
        var destY: Int
        var stagingX: Int = 0
        var stagingY: Int = 0
        var uv: SIMD4<Float>
    }

    init?(device: MTLDevice, side: Int = SSHTerminalGlyphAtlas.side) {
        self.side = max(1, side)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: self.side, height: self.side, mipmapped: false
        )
        // Blit destination + sample. Private: CPU never calls replace on it.
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    func resetPacking() {
        map.removeAll(keepingCapacity: true)
        x = 0
        y = 0
        rowHeight = 0
    }

    func key(cell: SSHTerminalCell, face: UInt8) -> GlyphKey {
        GlyphKey(face: face, scalar: cell.cluster == nil ? cell.scalar : 0, cluster: cell.cluster ?? "")
    }

    func cachedUV(_ key: GlyphKey) -> SIMD4<Float>? { map[key] }

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
        guard let origin = placeRect(width: pixelWidth, height: pixelHeight) else { return nil }
        guard let bytes = Self.rasterize(
            text: cell.displayText, font: font,
            width: pixelWidth, height: pixelHeight,
            cellSize: cellSize, columns: columns, scale: scale
        ) else { return nil }
        let s = Float(side)
        let uv = SIMD4<Float>(
            Float(origin.x) / s, Float(origin.y) / s,
            Float(origin.x + pixelWidth) / s, Float(origin.y + pixelHeight) / s
        )
        map[key] = uv
        return Upload(
            bytes: bytes, width: pixelWidth, height: pixelHeight,
            destX: origin.x, destY: origin.y, uv: uv
        )
    }

    private func placeRect(width: Int, height: Int) -> (x: Int, y: Int)? {
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

    /// Same draw as the old CPU painter: white ink at the cell origin, clipped
    /// to the cell, at device scale, so atlas coverage matches today's look.
    private static func rasterize(
        text: String, font: UIFont,
        width: Int, height: Int,
        cellSize: CGSize, columns: Int, scale: CGFloat
    ) -> [UInt8]? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let points = CGSize(width: cellSize.width * CGFloat(columns), height: cellSize.height)
        let image = UIGraphicsImageRenderer(size: points, format: format).image { ctx in
            let area = CGRect(origin: .zero, size: points)
            ctx.cgContext.clip(to: area)
            (text as NSString).draw(at: area.origin, withAttributes: [
                .font: font,
                .foregroundColor: UIColor.white,
            ])
        }
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

/// Instanced cell quads. Three instance-buffer slots; a slot is not rewritten
/// until its command buffer completion handler runs.
final class SSHTerminalMetalRenderer: @unchecked Sendable {
    static let ringSize = 3
    static let glyphFlag: UInt32 = 1

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
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let solid: MTLRenderPipelineState
    private let overlay: MTLRenderPipelineState
    private let glyph: MTLRenderPipelineState
    private let atlas: SSHTerminalGlyphAtlas
    private let lock = NSLock()
    private var slots: [Slot]
    private var faces = [UInt8: UIFont]()
    var metrics: SSHTerminalCellMetrics
    var scale: CGFloat

    private struct Slot {
        var buffer: MTLBuffer
        var capacity: Int
        var inFlight: Bool
        /// Shared staging for this slot's glyph blits. CPU-written only while
        /// the slot is free, then sampled by that same command buffer.
        var staging: MTLTexture?
    }

    enum RendererError: Error {
        case noBuffer
        case noAtlas
    }

    init(
        pipeline: SSHTerminalMetalPipeline,
        metrics: SSHTerminalCellMetrics,
        scale: CGFloat,
        atlasSide: Int = SSHTerminalGlyphAtlas.side
    ) throws {
        self.device = pipeline.device
        self.queue = pipeline.queue
        self.solid = pipeline.solid
        self.overlay = pipeline.overlay
        self.glyph = pipeline.glyph
        self.metrics = metrics
        self.scale = max(scale, 1)
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
            built.append(Slot(buffer: buffer, capacity: initial, inFlight: false, staging: nil))
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
    }

    func encode(
        frame: SSHTerminalFrame,
        cursorColor: SIMD4<Float>,
        drawable: CAMetalDrawable
    ) -> SSHTerminalMetalFrameCost {
        encode(
            frame: frame,
            cursorColor: cursorColor,
            target: drawable.texture,
            drawable: drawable,
            waitUntilCompleted: false
        )
    }

    func encodeOffscreen(
        frame: SSHTerminalFrame,
        cursorColor: SIMD4<Float>,
        texture: MTLTexture,
        waitUntilCompleted: Bool
    ) -> SSHTerminalMetalFrameCost {
        encode(
            frame: frame,
            cursorColor: cursorColor,
            target: texture,
            drawable: nil,
            waitUntilCompleted: waitUntilCompleted
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
        waitUntilCompleted: Bool
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
            if !uploads.isEmpty { atlas.resetPacking() }
            var cost = failed
            cost.miss = miss
            cost.errorDescription = reason
            return cost
        }
        let encodeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let packed = pack(frame: frame, cursorColor: cursorColor) else {
            return abort(miss: .deterministic, reason: "glyph atlas cannot fit this frame")
        }
        guard let slotIndex = bind(packed.all) else {
            return abort(
                uploads: packed.uploads, miss: .transient, reason: "no free Metal instance slot"
            )
        }
        var uploads = packed.uploads
        let staging: MTLTexture?
        if uploads.isEmpty {
            staging = nil
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
        if let staging, !uploads.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                return abort(
                    slot: slotIndex, uploads: uploads,
                    miss: .transient, reason: "makeBlitCommandEncoder returned nil"
                )
            }
            // Same queue as prior atlas samples: the blit waits for those reads,
            // then this frame's draw samples the new texels.
            for upload in uploads {
                blit.copy(
                    from: staging,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: upload.stagingX, y: upload.stagingY, z: 0),
                    sourceSize: MTLSize(width: upload.width, height: upload.height, depth: 1),
                    to: atlas.texture,
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
        var uniforms = Uniforms(viewportX: Float(target.width), viewportY: Float(target.height))
        let backgrounds = packed.backgrounds
        let glyphs = packed.glyphs
        let overlays = packed.overlays
        let stride = MemoryLayout<CellInstance>.stride
        if !backgrounds.isEmpty {
            encoder.setRenderPipelineState(solid)
            encoder.setVertexBuffer(slots[slotIndex].buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: backgrounds.count)
        }
        if !glyphs.isEmpty {
            encoder.setRenderPipelineState(glyph)
            encoder.setVertexBuffer(
                slots[slotIndex].buffer,
                offset: backgrounds.count * stride,
                index: 0
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        if !overlays.isEmpty {
            encoder.setRenderPipelineState(overlay)
            encoder.setVertexBuffer(
                slots[slotIndex].buffer,
                offset: (backgrounds.count + glyphs.count) * stride,
                index: 0
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: overlays.count)
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
                errorDescription: commandBuffer.error.map(String.init(describing:))
            )
        }
        return SSHTerminalMetalFrameCost(
            encodeNanos: encodeNanos,
            submitted: true,
            completed: false,
            status: commandBuffer.status,
            errorDescription: nil
        )
    }

    private struct PackedInstances {
        var backgrounds: [CellInstance]
        var glyphs: [CellInstance]
        var overlays: [CellInstance]
        var uploads: [SSHTerminalGlyphAtlas.Upload]
        var all: [CellInstance] { backgrounds + glyphs + overlays }
    }

    private func pack(frame: SSHTerminalFrame, cursorColor: SIMD4<Float>) -> PackedInstances? {
        if let packed = packOnce(frame: frame, cursorColor: cursorColor) { return packed }
        atlas.resetPacking()
        if let packed = packOnce(frame: frame, cursorColor: cursorColor) { return packed }
        // Second pack still missed: drop keys place() already inserted so a
        // later frame cannot treat un-uploaded texels as resident.
        atlas.resetPacking()
        return nil
    }

    private func packOnce(frame: SSHTerminalFrame, cursorColor: SIMD4<Float>) -> PackedInstances? {
        let cell = metrics.cellSize
        let scale = scale
        let cellW = Float(cell.width * scale)
        let cellH = Float(cell.height * scale)
        var backgrounds = [CellInstance]()
        var glyphs = [CellInstance]()
        var overlays = [CellInstance]()
        var uploads = [SSHTerminalGlyphAtlas.Upload]()
        backgrounds.reserveCapacity(max(1, frame.rows.count * (frame.rows.first?.count ?? 0)))
        let defaultBg = Self.rgba(frame.background)
        for (y, row) in frame.rows.enumerated() {
            for (x, item) in row.enumerated() {
                guard item.width > 0 else { continue }
                let origin = SIMD2<Float>(Float(x) * cellW, Float(y) * cellH)
                let size = SIMD2<Float>(Float(item.width) * cellW, cellH)
                let colors = Self.paintColors(item)
                if colors.bg != defaultBg {
                    backgrounds.append(CellInstance(origin: origin, size: size, color: colors.bg, uv: .zero, flags: 0))
                }
                // Invisible cells keep their background and draw nothing else,
                // matching the old painter's early return.
                guard !item.style.invisible else { continue }
                var fg = colors.fg
                if item.style.faint { fg = Self.premultiply(fg, alpha: 0.5) }
                if item.style.underline != 0 {
                    let yOff = underlineY(scale: scale)
                    overlays.append(CellInstance(
                        origin: SIMD2(origin.x, origin.y + yOff.y),
                        size: SIMD2(size.x, yOff.h),
                        color: fg, uv: .zero, flags: 0
                    ))
                }
                if item.style.strikethrough {
                    overlays.append(CellInstance(
                        origin: SIMD2(origin.x, origin.y + cellH * 0.5 - 1),
                        size: SIMD2(size.x, max(1, Float(scale))),
                        color: fg, uv: .zero, flags: 0
                    ))
                }
                guard item.hasInk else { continue }
                let face = face(bold: item.style.bold, italic: item.style.italic, text: item)
                let key = atlas.key(cell: item, face: face.key)
                let uv: SIMD4<Float>
                if let cached = atlas.cachedUV(key) {
                    uv = cached
                } else if let upload = atlas.place(
                    cell: item, face: face.key, font: face.font,
                    cellSize: cell, scale: scale
                ) {
                    uploads.append(upload)
                    uv = upload.uv
                } else {
                    return nil
                }
                glyphs.append(CellInstance(origin: origin, size: size, color: fg, uv: uv, flags: Self.glyphFlag))
            }
        }
        if let cursor = cursorQuad(
            frame: frame, color: Self.premultiply(cursorColor), cellW: cellW, cellH: cellH
        ) {
            overlays.append(contentsOf: cursor)
        }
        return PackedInstances(backgrounds: backgrounds, glyphs: glyphs, overlays: overlays, uploads: uploads)
    }

    private func prepareStaging(slot: Int, uploads: inout [SSHTerminalGlyphAtlas.Upload]) -> MTLTexture? {
        var x = 0, y = 0, rowHeight = 0, stagedWidth = 1, stagedHeight = 1
        // Same shelf as the atlas: a set of glyphs that packed into the atlas
        // packs into staging. Never exceed the device 2D cap (simulator Metal
        // validation is 8192; Apple GPUs in this app are 16384).
        let shelf = min(atlas.side, 8192)
        for i in uploads.indices {
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
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(slot) else { return nil }
        let staging: MTLTexture
        if let existing = slots[slot].staging,
           existing.width >= stagedWidth, existing.height >= stagedHeight {
            staging = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: stagedWidth, height: stagedHeight, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let created = device.makeTexture(descriptor: descriptor) else { return nil }
            slots[slot].staging = created
            staging = created
        }
        for upload in uploads {
            upload.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                staging.replace(
                    region: MTLRegionMake2D(upload.stagingX, upload.stagingY, upload.width, upload.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: upload.width * 4
                )
            }
        }
        return staging
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
           !Self.covers(styled, text.displayText),
           let symbols = NerdFontSymbols.font(size: metrics.font.pointSize) {
            if let cached = faces[4] { return (4, cached) }
            faces[4] = symbols
            return (4, symbols)
        }
        return (key, styled)
    }

    private static func covers(_ font: UIFont, _ text: String) -> Bool {
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
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
