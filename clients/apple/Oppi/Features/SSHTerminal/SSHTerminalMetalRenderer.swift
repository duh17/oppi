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

struct SSHTerminalMetalFrameCost: Sendable {
    var encodeNanos: UInt64
    var submitted: Bool
    var completed: Bool
    var status: MTLCommandBufferStatus
    var errorDescription: String?
}

/// Process-wide pipeline from the precompiled metallib. Built off the main
/// thread so first open does not stall on `makeRenderPipelineState`.
final class SSHTerminalMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let solid: MTLRenderPipelineState
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
        self.glyph = try pipeline(glyphFn, blending: true)
    }
}

/// Core Text glyphs rasterized once at device scale, keyed by grapheme + face.
/// Grows by packing into unused atlas space; a full atlas resets when no
/// command buffer is sampling it.
final class SSHTerminalGlyphAtlas {
    static let side = 2048
    let texture: MTLTexture
    private var map = [GlyphKey: SIMD4<Float>]()
    private var x = 0
    private var y = 0
    private var rowHeight = 0
    private(set) var pendingReset = false
    private let side: Int

    struct GlyphKey: Hashable {
        var face: UInt8
        var scalar: UInt32
        var cluster: String
    }

    init?(device: MTLDevice, side: Int = SSHTerminalGlyphAtlas.side) {
        self.side = side
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        clear()
    }

    func reset() {
        map.removeAll(keepingCapacity: true)
        x = 0
        y = 0
        rowHeight = 0
        pendingReset = false
        clear()
    }

    func markNeedsReset() {
        pendingReset = true
    }

    func uv(
        cell: SSHTerminalCell,
        face: UInt8,
        font: UIFont,
        cellSize: CGSize,
        scale: CGFloat,
        inFlight: Bool
    ) -> SIMD4<Float>? {
        let key = GlyphKey(face: face, scalar: cell.cluster == nil ? cell.scalar : 0, cluster: cell.cluster ?? "")
        if let uv = map[key] { return uv }
        let columns = max(1, cell.width)
        let pixelWidth = max(1, Int(ceil(cellSize.width * CGFloat(columns) * scale)))
        let pixelHeight = max(1, Int(ceil(cellSize.height * scale)))
        if pixelWidth > side || pixelHeight > side { return nil }
        if x + pixelWidth > side {
            x = 0
            y += rowHeight
            rowHeight = 0
        }
        if y + pixelHeight > side {
            // Do not wipe texels a command buffer is still sampling.
            if inFlight {
                pendingReset = true
                return nil
            }
            reset()
            if pixelWidth > side || pixelHeight > side { return nil }
        }
        guard let bytes = Self.rasterize(
            text: cell.displayText, font: font,
            width: pixelWidth, height: pixelHeight,
            cellSize: cellSize, columns: columns, scale: scale
        ) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(x, y, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: pixelWidth * 4
        )
        let s = Float(side)
        let uv = SIMD4<Float>(
            Float(x) / s, Float(y) / s,
            Float(x + pixelWidth) / s, Float(y + pixelHeight) / s
        )
        map[key] = uv
        x += pixelWidth
        rowHeight = max(rowHeight, pixelHeight)
        return uv
    }

    private func clear() {
        let row = [UInt8](repeating: 0, count: side * 4)
        for rowIndex in 0..<side {
            row.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, rowIndex, side, 1),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: side * 4
                )
            }
        }
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
    }

    enum RendererError: Error {
        case noBuffer
        case noAtlas
    }

    init(pipeline: SSHTerminalMetalPipeline, metrics: SSHTerminalCellMetrics, scale: CGFloat) throws {
        self.device = pipeline.device
        self.queue = pipeline.queue
        self.solid = pipeline.solid
        self.glyph = pipeline.glyph
        self.metrics = metrics
        self.scale = max(scale, 1)
        guard let atlas = SSHTerminalGlyphAtlas(device: pipeline.device) else { throw RendererError.noAtlas }
        self.atlas = atlas
        var built: [Slot] = []
        built.reserveCapacity(Self.ringSize)
        let initial = 256
        for _ in 0..<Self.ringSize {
            guard let buffer = device.makeBuffer(
                length: initial * MemoryLayout<CellInstance>.stride,
                options: .storageModeShared
            ) else { throw RendererError.noBuffer }
            built.append(Slot(buffer: buffer, capacity: initial, inFlight: false))
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
        if inFlightCount == 0 {
            atlas.reset()
        } else {
            atlas.markNeedsReset()
        }
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
            encodeNanos: 0, submitted: false, completed: false, status: .error, errorDescription: nil
        )
        if atlas.pendingReset {
            if inFlightCount > 0 {
                var miss = failed
                miss.errorDescription = "atlas reset waiting for in-flight frames"
                return miss
            }
            atlas.reset()
        }
        let encodeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let instances = pack(frame: frame, cursorColor: cursorColor)
        guard let slotIndex = bind(instances.all) else {
            var miss = failed
            miss.errorDescription = "no free Metal instance slot"
            return miss
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            releaseSlot(slotIndex)
            var miss = failed
            miss.errorDescription = "makeCommandBuffer returned nil"
            return miss
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
            releaseSlot(slotIndex)
            var miss = failed
            miss.errorDescription = "makeRenderCommandEncoder returned nil"
            return miss
        }
        var uniforms = Uniforms(viewportX: Float(target.width), viewportY: Float(target.height))
        let packed = instances
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
            encoder.setRenderPipelineState(solid)
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
        var all: [CellInstance] { backgrounds + glyphs + overlays }
    }

    private func pack(frame: SSHTerminalFrame, cursorColor: SIMD4<Float>) -> PackedInstances {
        let cell = metrics.cellSize
        let scale = scale
        let cellW = Float(cell.width * scale)
        let cellH = Float(cell.height * scale)
        let inFlight = inFlightCount > 0
        var backgrounds = [CellInstance]()
        var glyphs = [CellInstance]()
        var overlays = [CellInstance]()
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
                if item.style.underline != 0 {
                    let yOff = underlineY(scale: scale)
                    overlays.append(CellInstance(
                        origin: SIMD2(origin.x, origin.y + yOff.y),
                        size: SIMD2(size.x, yOff.h),
                        color: colors.fg, uv: .zero, flags: 0
                    ))
                }
                if item.style.strikethrough {
                    overlays.append(CellInstance(
                        origin: SIMD2(origin.x, origin.y + cellH * 0.5 - 1),
                        size: SIMD2(size.x, max(1, Float(scale))),
                        color: colors.fg, uv: .zero, flags: 0
                    ))
                }
                guard !item.style.invisible, item.hasInk else { continue }
                let face = face(bold: item.style.bold, italic: item.style.italic, text: item)
                if let uv = atlas.uv(
                    cell: item, face: face.key, font: face.font,
                    cellSize: cell, scale: scale, inFlight: inFlight
                ) {
                    var fg = colors.fg
                    if item.style.faint { fg.w *= 0.5; fg.x *= 0.5; fg.y *= 0.5; fg.z *= 0.5 }
                    glyphs.append(CellInstance(origin: origin, size: size, color: fg, uv: uv, flags: Self.glyphFlag))
                }
            }
        }
        if let cursor = cursorQuad(frame: frame, color: cursorColor, cellW: cellW, cellH: cellH) {
            overlays.append(contentsOf: cursor)
        }
        return PackedInstances(backgrounds: backgrounds, glyphs: glyphs, overlays: overlays)
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
        slots[index].inFlight = true
        return index
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
        SIMD4(Float(rgb.r) / 255, Float(rgb.g) / 255, Float(rgb.b) / 255, alpha)
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
