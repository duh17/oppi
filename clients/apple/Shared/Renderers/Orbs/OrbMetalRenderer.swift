import Foundation
import Metal
import os
import QuartzCore

struct OrbTint: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var isDark: Bool

    static let darkFallback = Self(red: 0.92, green: 0.92, blue: 0.94, isDark: true)

    func repeatingPalette() -> OrbPalette {
        let color = SIMD3<Float>(red, green, blue)
        return OrbPalette(accents: [color, color, color, color])
    }

    static func isDarkBackground(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        (0.2126 * red + 0.7152 * green + 0.0722 * blue) < 0.5
    }
}

struct OrbPalette: Equatable, Sendable {
    /// Blue, cyan, purple, orange slots. Always four.
    var accents: [SIMD3<Float>]

    static let empty = Self(accents: [
        SIMD3(0.35, 0.55, 0.95),
        SIMD3(0.30, 0.75, 0.85),
        SIMD3(0.62, 0.48, 0.90),
        SIMD3(0.95, 0.62, 0.32),
    ])

    func color(_ index: Int) -> SIMD3<Float> {
        guard !accents.isEmpty else { return SIMD3(1, 1, 1) }
        return accents[((index % accents.count) + accents.count) % accents.count]
    }
}

/// Process-wide immutable Metal setup. Vertex rings stay per renderer instance.
final class OrbMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: OrbMetalPipeline?
    nonisolated(unsafe) private static var cachedError: String?

    static func shared() throws -> OrbMetalPipeline {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let cachedError { throw OrbMetalRenderer.RendererError.pipeline(cachedError) }
        do {
            let built = try OrbMetalPipeline()
            cached = built
            return built
        } catch {
            cachedError = String(describing: error)
            throw error
        }
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw OrbMetalRenderer.RendererError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw OrbMetalRenderer.RendererError.noCommandQueue
        }
        let library = try device.makeLibrary(source: OrbMetalRenderer.shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "vertex_dot") else {
            throw OrbMetalRenderer.RendererError.missingFunction("vertex_dot")
        }
        guard let fragment = library.makeFunction(name: "fragment_dot") else {
            throw OrbMetalRenderer.RendererError.missingFunction("fragment_dot")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

struct OrbMetalFrameCost: Sendable {
    var encodeNanos: UInt64
    var submitNanos: UInt64
    var status: MTLCommandBufferStatus
    var errorDescription: String?
    var submitted: Bool
    var completed: Bool
}

/// Batched Metal rasterizer for orb dots.
///
/// Three immutable vertex slots. A slot is not rewritten until its command
/// buffer completion handler runs, including failure. Live drawing never waits
/// on the GPU from the display-link thread.
final class OrbMetalRenderer: @unchecked Sendable {
    static let ringSize = 3

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var slots: [Slot]
    var onFinished: (@Sendable (OrbMetalFrameCost) -> Void)?

    private struct Slot {
        var buffer: MTLBuffer
        var capacity: Int
        var inFlight: Bool
    }

    struct MetalDot {
        var centerX: Float
        var centerY: Float
        var radius: Float
        var white: Float
        var alpha: Float
        var pad0: Float
        var pad1: Float
        var pad2: Float
    }

    struct Uniforms {
        var viewportX: Float
        var viewportY: Float
        var dark: Float
        var pad: Float
        var tintR: Float
        var tintG: Float
        var tintB: Float
        var tintA: Float
        var accent0R: Float, accent0G: Float, accent0B: Float, accent0A: Float
        var accent1R: Float, accent1G: Float, accent1B: Float, accent1A: Float
        var accent2R: Float, accent2G: Float, accent2B: Float, accent2A: Float
        var accent3R: Float, accent3G: Float, accent3B: Float, accent3A: Float
    }

    enum RendererError: Error {
        case noDevice
        case noCommandQueue
        case missingFunction(String)
        case noBuffer
        case pipeline(String)
    }

    /// Injected into the production encode path. Never points at an invalid texture.
    enum EncodeFault: Sendable {
        case none
        case nilCommandBuffer
        case nilEncoder
    }

    var encodeFault: EncodeFault = .none

    static func make() -> (renderer: OrbMetalRenderer?, unavailableReason: String?) {
        do {
            let shared = try OrbMetalPipeline.shared()
            return (try OrbMetalRenderer(shared: shared), nil)
        } catch {
            return (nil, String(describing: error))
        }
    }

    init(shared: OrbMetalPipeline) throws {
        self.device = shared.device
        self.queue = shared.queue
        self.pipeline = shared.pipeline
        let initialCount = 64
        var built: [Slot] = []
        built.reserveCapacity(Self.ringSize)
        for _ in 0..<Self.ringSize {
            guard let buffer = device.makeBuffer(
                length: initialCount * MemoryLayout<MetalDot>.stride,
                options: .storageModeShared
            ) else {
                throw RendererError.noBuffer
            }
            built.append(Slot(buffer: buffer, capacity: initialCount, inFlight: false))
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

    func encode(
        dots: [OrbDot],
        designSize: Double,
        drawable: CAMetalDrawable,
        tint: OrbTint,
        palette: OrbPalette? = nil
    ) -> OrbMetalFrameCost {
        encode(
            dots: dots,
            designSize: designSize,
            target: drawable.texture,
            drawable: drawable,
            tint: tint,
            palette: palette ?? tint.repeatingPalette()
        )
    }

    func encodeOffscreen(
        dots: [OrbDot],
        designSize: Double,
        texture: MTLTexture,
        tint: OrbTint,
        waitUntilCompleted: Bool,
        palette: OrbPalette? = nil
    ) -> OrbMetalFrameCost {
        encode(
            dots: dots,
            designSize: designSize,
            target: texture,
            drawable: nil,
            tint: tint,
            palette: palette ?? tint.repeatingPalette(),
            waitUntilCompleted: waitUntilCompleted
        )
    }

    func makeOffscreenTexture(width: Int, height: Int, renderTarget: Bool) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        if renderTarget {
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
        } else {
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
        }
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(
        dots: [OrbDot],
        designSize: Double,
        target: MTLTexture,
        drawable: CAMetalDrawable?,
        tint: OrbTint,
        palette: OrbPalette,
        waitUntilCompleted: Bool = false
    ) -> OrbMetalFrameCost {
        let failed = OrbMetalFrameCost(
            encodeNanos: 0,
            submitNanos: 0,
            status: .error,
            errorDescription: nil,
            submitted: false,
            completed: false
        )
        let encodeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        guard let slotIndex = packDots(dots, designSize: designSize, viewport: viewport) else {
            var miss = failed
            miss.errorDescription = "no free Metal vertex slot"
            return miss
        }
        if encodeFault == .nilCommandBuffer {
            releaseSlot(slotIndex)
            var miss = failed
            miss.errorDescription = "makeCommandBuffer returned nil"
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
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if encodeFault == .nilEncoder {
            releaseSlot(slotIndex)
            var miss = failed
            miss.errorDescription = "makeRenderCommandEncoder returned nil"
            return miss
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            releaseSlot(slotIndex)
            var miss = failed
            miss.errorDescription = "makeRenderCommandEncoder returned nil"
            return miss
        }
        encoder.setRenderPipelineState(pipeline)
        let a0 = palette.color(0)
        let a1 = palette.color(1)
        let a2 = palette.color(2)
        let a3 = palette.color(3)
        var uniforms = Uniforms(
            viewportX: viewport.x,
            viewportY: viewport.y,
            dark: tint.isDark ? 1 : 0,
            pad: 0,
            tintR: tint.red,
            tintG: tint.green,
            tintB: tint.blue,
            tintA: 1,
            accent0R: a0.x, accent0G: a0.y, accent0B: a0.z, accent0A: 1,
            accent1R: a1.x, accent1G: a1.y, accent1B: a1.z, accent1A: 1,
            accent2R: a2.x, accent2G: a2.y, accent2B: a2.z, accent2A: 1,
            accent3R: a3.x, accent3G: a3.y, accent3B: a3.z, accent3A: 1
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if !dots.isEmpty {
            encoder.setVertexBuffer(slots[slotIndex].buffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: dots.count
            )
        }
        encoder.endEncoding()
        let encodeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - encodeStart
        if let drawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.addCompletedHandler { [weak self] finished in
            guard let self else { return }
            self.releaseSlot(slotIndex)
            let status = finished.status
            let cost = OrbMetalFrameCost(
                encodeNanos: encodeNanos,
                submitNanos: 0,
                status: status,
                errorDescription: finished.error.map(String.init(describing:)),
                submitted: true,
                completed: status == .completed
            )
            self.onFinished?(cost)
        }

        let submitStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        commandBuffer.commit()
        let submitNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submitStart

        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
            return OrbMetalFrameCost(
                encodeNanos: encodeNanos,
                submitNanos: submitNanos,
                status: commandBuffer.status,
                errorDescription: commandBuffer.error.map(String.init(describing:)),
                submitted: true,
                completed: commandBuffer.status == .completed
            )
        }

        return OrbMetalFrameCost(
            encodeNanos: encodeNanos,
            submitNanos: submitNanos,
            status: commandBuffer.status,
            errorDescription: commandBuffer.error.map(String.init(describing:)),
            submitted: true,
            completed: false
        )
    }

    private func packDots(
        _ dots: [OrbDot],
        designSize: Double,
        viewport: SIMD2<Float>
    ) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = slots.firstIndex(where: { !$0.inFlight }) else { return nil }
        let needed = max(dots.count, 64)
        if needed > slots[index].capacity {
            guard let grown = device.makeBuffer(
                length: needed * MemoryLayout<MetalDot>.stride,
                options: .storageModeShared
            ) else {
                return nil
            }
            slots[index].buffer = grown
            slots[index].capacity = needed
        }
        let buffer = slots[index].buffer
        let side = min(viewport.x, viewport.y)
        let scale = designSize > 0 ? Float(side) / Float(designSize) : 1
        let offsetX = (viewport.x - Float(designSize) * scale) / 2
        let offsetY = (viewport.y - Float(designSize) * scale) / 2
        let pointer = buffer.contents().bindMemory(to: MetalDot.self, capacity: slots[index].capacity)
        for (i, dot) in dots.enumerated() {
            pointer[i] = MetalDot(
                centerX: offsetX + Float(dot.x) * scale,
                centerY: offsetY + Float(dot.y) * scale,
                radius: Float(dot.r) * scale,
                white: Float(dot.white),
                alpha: Float(dot.a),
                pad0: Float(dot.accent),
                pad1: Float(dot.palette),
                pad2: 0
            )
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

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Dot {
        float4 centerRadiusWhite;
        float4 alphaPad;
    };

    struct Uniforms {
        float4 viewportDarkPad;
        float4 tint;
        float4 accent0;
        float4 accent1;
        float4 accent2;
        float4 accent3;
    };

    struct VOut {
        float4 position [[position]];
        float2 local;
        float white;
        float alpha;
        float accent;
        float palette;
    };

    vertex VOut vertex_dot(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant Dot *dots [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
        float2 corners[4] = { float2(-1.25, -1.25), float2(1.25, -1.25), float2(-1.25, 1.25), float2(1.25, 1.25) };
        float2 local = corners[vid];
        Dot d = dots[iid];
        float2 center = d.centerRadiusWhite.xy;
        float radius = d.centerRadiusWhite.z;
        float2 px = center + local * radius;
        float2 ndc = float2((px.x / u.viewportDarkPad.x) * 2.0 - 1.0,
                            1.0 - (px.y / u.viewportDarkPad.y) * 2.0);
        VOut outv;
        outv.position = float4(ndc, 0.0, 1.0);
        outv.local = local;
        outv.white = d.centerRadiusWhite.w;
        outv.alpha = d.alphaPad.x;
        outv.accent = d.alphaPad.y;
        outv.palette = d.alphaPad.z;
        return outv;
    }

    fragment float4 fragment_dot(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float dist = length(in.local);
        float fw = max(fwidth(dist), 1e-4);
        float coverage = saturate((1.0 - dist) / fw + 0.5);
        if (coverage <= 0.0) {
            discard_fragment();
        }
        float amount = saturate(1.0 - in.white);
        float a = saturate(in.alpha) * coverage;
        float3 accent = in.palette < 0.5 ? u.accent0.xyz
                      : in.palette < 1.5 ? u.accent1.xyz
                      : in.palette < 2.5 ? u.accent2.xyz
                      : u.accent3.xyz;
        float3 hue = mix(u.tint.xyz, accent, saturate(in.accent));
        // Dark: dim toward black. Light: fade toward paper, never multiply a
        // dark accent into a black disk.
        float3 color = u.viewportDarkPad.z > 0.5
            ? hue * amount
            : mix(float3(1.0, 1.0, 1.0), hue, saturate(0.45 + 0.55 * amount));
        return float4(color * a, a);
    }
    """
}

enum OrbLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi",
        category: "Orb"
    )
}
