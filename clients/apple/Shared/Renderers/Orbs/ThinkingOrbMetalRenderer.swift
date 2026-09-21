import Foundation
import Metal
import os
import QuartzCore

struct ThinkingOrbTint: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var isDark: Bool

    static let lightFallback = ThinkingOrbTint(red: 0.12, green: 0.12, blue: 0.14, isDark: false)
    static let darkFallback = ThinkingOrbTint(red: 0.92, green: 0.92, blue: 0.94, isDark: true)

    static func isDarkBackground(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        (0.2126 * red + 0.7152 * green + 0.0722 * blue) < 0.5
    }
}

/// Process-wide immutable Metal setup. Vertex rings stay per renderer instance.
final class ThinkingOrbMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: ThinkingOrbMetalPipeline?
    nonisolated(unsafe) private static var cachedError: String?

    static func shared() throws -> ThinkingOrbMetalPipeline {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let cachedError { throw ThinkingOrbMetalRenderer.RendererError.pipeline(cachedError) }
        do {
            let built = try ThinkingOrbMetalPipeline()
            cached = built
            return built
        } catch {
            cachedError = String(describing: error)
            throw error
        }
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ThinkingOrbMetalRenderer.RendererError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw ThinkingOrbMetalRenderer.RendererError.noCommandQueue
        }
        let library = try device.makeLibrary(source: ThinkingOrbMetalRenderer.shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "vertex_dot") else {
            throw ThinkingOrbMetalRenderer.RendererError.missingFunction("vertex_dot")
        }
        guard let fragment = library.makeFunction(name: "fragment_dot") else {
            throw ThinkingOrbMetalRenderer.RendererError.missingFunction("fragment_dot")
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

struct ThinkingOrbMetalFrameCost: Sendable {
    var encodeNanos: UInt64
    var submitNanos: UInt64
    var status: MTLCommandBufferStatus
    var errorDescription: String?
    var submitted: Bool
    var completed: Bool
}

/// Batched Metal rasterizer for thinking-orb dots.
///
/// Three immutable vertex slots. A slot is not rewritten until its command
/// buffer completion handler runs, including failure. Live drawing never waits
/// on the GPU from the display-link thread.
final class ThinkingOrbMetalRenderer: @unchecked Sendable {
    static let ringSize = 3

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var slots: [Slot]
    var onFinished: (@Sendable (ThinkingOrbMetalFrameCost) -> Void)?

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

    static func make() -> (renderer: ThinkingOrbMetalRenderer?, unavailableReason: String?) {
        do {
            let shared = try ThinkingOrbMetalPipeline.shared()
            return (try ThinkingOrbMetalRenderer(shared: shared), nil)
        } catch {
            return (nil, String(describing: error))
        }
    }

    init(shared: ThinkingOrbMetalPipeline) throws {
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
        dots: [ThinkingOrbDot],
        designSize: Double,
        drawable: CAMetalDrawable,
        tint: ThinkingOrbTint
    ) -> ThinkingOrbMetalFrameCost {
        encode(
            dots: dots,
            designSize: designSize,
            target: drawable.texture,
            drawable: drawable,
            tint: tint
        )
    }

    func encodeOffscreen(
        dots: [ThinkingOrbDot],
        designSize: Double,
        texture: MTLTexture,
        tint: ThinkingOrbTint,
        waitUntilCompleted: Bool
    ) -> ThinkingOrbMetalFrameCost {
        encode(
            dots: dots,
            designSize: designSize,
            target: texture,
            drawable: nil,
            tint: tint,
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
        dots: [ThinkingOrbDot],
        designSize: Double,
        target: MTLTexture,
        drawable: CAMetalDrawable?,
        tint: ThinkingOrbTint,
        waitUntilCompleted: Bool = false
    ) -> ThinkingOrbMetalFrameCost {
        let failed = ThinkingOrbMetalFrameCost(
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
        var uniforms = Uniforms(
            viewportX: viewport.x,
            viewportY: viewport.y,
            dark: tint.isDark ? 1 : 0,
            pad: 0,
            tintR: tint.red,
            tintG: tint.green,
            tintB: tint.blue,
            tintA: 1
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
            let cost = ThinkingOrbMetalFrameCost(
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
            return ThinkingOrbMetalFrameCost(
                encodeNanos: encodeNanos,
                submitNanos: submitNanos,
                status: commandBuffer.status,
                errorDescription: commandBuffer.error.map(String.init(describing:)),
                submitted: true,
                completed: commandBuffer.status == .completed
            )
        }

        return ThinkingOrbMetalFrameCost(
            encodeNanos: encodeNanos,
            submitNanos: submitNanos,
            status: commandBuffer.status,
            errorDescription: commandBuffer.error.map(String.init(describing:)),
            submitted: true,
            completed: false
        )
    }

    private func packDots(
        _ dots: [ThinkingOrbDot],
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
                pad0: 0, pad1: 0, pad2: 0
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
    };

    struct VOut {
        float4 position [[position]];
        float2 local;
        float white;
        float alpha;
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
        return outv;
    }

    fragment float4 fragment_dot(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float dist = length(in.local);
        float fw = max(fwidth(dist), 1e-4);
        float coverage = saturate((1.0 - dist) / fw + 0.5);
        if (coverage <= 0.0) {
            discard_fragment();
        }
        float ink = u.viewportDarkPad.z > 0.5 ? (1.0 - in.white) : in.white;
        float a = saturate(in.alpha) * coverage;
        ink = saturate(ink);
        float3 color = u.tint.xyz * ink;
        return float4(color * a, a);
    }
    """
}

enum ThinkingOrbLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi",
        category: "ThinkingOrb"
    )
}
