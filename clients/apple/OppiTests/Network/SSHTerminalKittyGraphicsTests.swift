import Compression
import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO
import Metal
import Testing
@testable import Oppi

/// Real Kitty graphics escape sequences through the real engine. No SSH host is
/// involved: these are the bytes a program such as `kitten icat`, chafa, or
/// Pi's image output writes to the terminal.
@Suite("SSH terminal kitty graphics", .serialized)
@MainActor
struct SSHTerminalKittyGraphicsTests {
    private static let geometry = SSHTerminalGeometry(columns: 40, rows: 10, cellWidth: 8, cellHeight: 17)

    private func engine(_ replies: @escaping (Data) -> Void = { _ in }) throws -> SSHTerminalEngine {
        try SSHTerminalEngine(geometry: Self.geometry, sink: replies)
    }

    /// `ESC _ G <control> ; <payload> ESC \`
    private func kitty(_ control: String, payload: String = "") -> Data {
        Data("\u{1b}_G\(control);\(payload)\u{1b}\\".utf8)
    }

    private struct Pixel {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8 = 255
    }

    private func rgbaPayload(_ pixels: [Pixel]) -> String {
        var bytes = [UInt8]()
        for pixel in pixels { bytes += [pixel.red, pixel.green, pixel.blue, pixel.alpha] }
        return Data(bytes).base64EncodedString()
    }

    @Test func directRGBAImageIsStoredPlacedAndAcknowledged() throws {
        var replies = [Data]()
        let engine = try engine { replies.append($0) }
        engine.receive(Data("\u{1b}[2;3H".utf8))
        let orange = Pixel(red: 0xFF, green: 0x80, blue: 0x00)
        engine.receive(kitty(
            "a=T,f=32,s=2,v=2,i=7,c=2,r=2",
            payload: rgbaPayload(Array(repeating: orange, count: 4))
        ))

        let frame = engine.frame()
        let kitty = try #require(frame.kitty, "an image must reach the frame")
        #expect(kitty.placements.count == 1)
        let placement = try #require(kitty.placements.first)
        #expect(placement.imageID == 7)
        #expect(placement.layer == .aboveText) // z default 0
        #expect(placement.viewportColumn == 2)
        #expect(placement.viewportRow == 1)
        #expect(placement.pixelWidth == 16) // 2 cells * 8 px
        #expect(placement.pixelHeight == 34) // 2 rows * 17 px
        #expect(placement.sourceX == 0 && placement.sourceY == 0)
        #expect(placement.sourceWidth == 2 && placement.sourceHeight == 2)
        #expect(placement.xOffset == 0 && placement.yOffset == 0)

        let image = try #require(kitty.images.first)
        #expect(image.id == 7)
        #expect(image.width == 2 && image.height == 2)
        #expect(image.format == .rgba)
        #expect(image.generation > 0)
        #expect(try pixelBytes(of: image, graphics: frame.kittyGraphics) == [0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF])
        // The host is told the image loaded; without a reply `kitten icat` gives up.
        #expect(replies.map { String(decoding: $0, as: UTF8.self) } == ["\u{1b}_Gi=7;OK\u{1b}\\"])
    }

    @Test func pngImageIsDecodedThroughImageIO() throws {
        let pngData = try png(width: 2, height: 2, rows: [
            [Pixel(red: 255, green: 0, blue: 0), Pixel(red: 255, green: 0, blue: 0)],
            [Pixel(red: 0, green: 0, blue: 255), Pixel(red: 0, green: 0, blue: 255)],
        ])
        var replies = [Data]()
        let engine = try engine { replies.append($0) }
        engine.receive(kitty("a=T,f=100,i=9,c=2,r=2", payload: pngData.base64EncodedString()))

        let frame = engine.frame()
        let kitty = try #require(frame.kitty)
        let image = try #require(kitty.images.first)
        #expect(image.width == 2 && image.height == 2)
        #expect(image.format == .rgba)
        #expect(try pixelBytes(of: image, graphics: frame.kittyGraphics) == [
            255, 0, 0, 255, 255, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255,
        ], "PNG decodes to straight-alpha RGBA, top row first")
        #expect(replies.map { String(decoding: $0, as: UTF8.self) } == ["\u{1b}_Gi=9;OK\u{1b}\\"])
    }

    @Test func supportQueryIsAnsweredBeforeAnyImageExists() throws {
        var replies = [Data]()
        let engine = try engine { replies.append($0) }
        // What `kitten icat` and Pi send to learn whether images are supported.
        engine.receive(kitty("i=31,s=1,v=1,a=q,t=d,f=24", payload: "AAAA"))
        #expect(replies.map { String(decoding: $0, as: UTF8.self) } == ["\u{1b}_Gi=31;OK\u{1b}\\"])
        #expect(engine.frame().kitty == nil, "a query stores nothing")
    }

    @Test func localFileAndSharedMemoryMediumsAreRefused() throws {
        var replies = [Data]()
        let engine = try engine { replies.append($0) }
        // A remote host must never make this device read local files.
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=1,t=f", payload: Data("/etc/passwd".utf8).base64EncodedString()))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=2,t=s", payload: Data("/shm,42".utf8).base64EncodedString()))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=3,t=t", payload: Data("/tmp/tty-graphics-protocol".utf8).base64EncodedString()))
        let shown = replies.map { String(decoding: $0, as: UTF8.self) }
        #expect(shown == [
            "\u{1b}_Gi=1;EINVAL: unsupported medium\u{1b}\\",
            "\u{1b}_Gi=2;EINVAL: unsupported medium\u{1b}\\",
            "\u{1b}_Gi=3;EINVAL: unsupported medium\u{1b}\\",
        ])
        #expect(engine.frame().kitty == nil)
    }

    @Test func placementsFollowScrollingAndKeepTheirSourceRect() throws {
        var sink = [Data]()
        let engine = try engine { sink.append($0) }
        engine.receive(Data((0..<30).map { "line \($0)\r\n" }.joined().utf8))
        engine.receive(Data("\u{1b}[2;1H".utf8))
        // 8x8 image, cropped to 4x4 at (2,2), two cells wide.
        engine.receive(kitty(
            "a=T,f=32,s=8,v=8,i=3,c=2,r=1,x=2,y=2,w=4,h=4",
            payload: rgbaPayload(Array(repeating: Pixel(red: 1, green: 2, blue: 3), count: 64))
        ))
        let top = try #require(engine.frame().kitty?.placements.first)
        #expect(top.viewportRow == 1)
        #expect(top.sourceWidth == 4 && top.sourceHeight == 4)
        #expect(top.sourceX == 2 && top.sourceY == 2)
        #expect(top.pixelWidth == 16) // cropped to a 2-cell box

        engine.scroll(rows: -3)
        let scrolled = try #require(engine.frame().kitty?.placements.first)
        // A negative delta moves the viewport back through history, so a
        // placement pinned to its screen row appears three rows lower.
        #expect(scrolled.viewportRow == 4, "the image is pinned to its rows, not the viewport")
        #expect(scrolled.pixelWidth == top.pixelWidth)
        engine.scroll(rows: 3)
        #expect(engine.frame().kitty?.placements.first?.viewportRow == 1, "scrolling forward returns it")
    }

    @Test func zIndexSelectsTheLayerTextIsDrawnOver() throws {
        let engine = try engine()
        let white = rgbaPayload([Pixel(red: 255, green: 255, blue: 255)])
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=1,c=1,r=1,z=5", payload: white))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=2,c=1,r=1,z=-1", payload: white))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=3,c=1,r=1,z=-2000000000", payload: white))
        let layers = Dictionary(uniqueKeysWithValues: try #require(engine.frame().kitty).placements.map { ($0.imageID, $0.layer) })
        #expect(layers == [1: .aboveText, 2: .belowText, 3: .belowBackground])
        #expect(SSHTerminalKittyLayer.allCases == [.belowBackground, .belowText, .aboveText])
    }

    @Test func deleteAndResetRemoveImages() throws {
        let engine = try engine()
        let white = rgbaPayload([Pixel(red: 255, green: 255, blue: 255)])
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=4,c=1,r=1", payload: white))
        #expect(engine.frame().kitty?.placements.count == 1)

        engine.receive(kitty("a=d,d=i,i=4"))
        let deleted = engine.frame().kitty
        #expect(deleted?.placements.isEmpty == true)
        #expect(deleted?.images.isEmpty == true)

        engine.receive(kitty("a=T,f=32,s=1,v=1,i=5,c=1,r=1", payload: white))
        #expect(engine.frame().kitty?.placements.count == 1)
        engine.receive(Data("\u{1b}c".utf8)) // RIS
        // A reset is reported once as an empty store, so the renderer drops every
        // texture; after that there is nothing to report at all.
        let reset = engine.frame().kitty
        #expect(reset?.placements.isEmpty == true)
        #expect(reset?.storedImageIDs.isEmpty == true)
        #expect(engine.frame().kitty == nil)
    }

    @Test func retransmittingAnImageReplacesItsPixels() throws {
        let engine = try engine()
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=8,c=1,r=1", payload: rgbaPayload([Pixel(red: 1, green: 1, blue: 1)])))
        let first = try #require(engine.frame().kitty?.images.first)
        let firstGeneration = first.generation

        engine.receive(kitty("a=T,f=32,s=1,v=1,i=8,c=1,r=1", payload: rgbaPayload([Pixel(red: 9, green: 9, blue: 9)])))
        let frame = engine.frame()
        let snapshot = try #require(frame.kitty)
        let second = try #require(snapshot.images.first)
        #expect(second.generation != firstGeneration)
        #expect(try pixelBytes(of: second, graphics: frame.kittyGraphics).first == 9)
        #expect(engine.frame().kitty?.placements.count == 1, "the replacement keeps one placement")
    }

    // MARK: - Metal texture cache

    @Test func textureIsUploadedOncePerImageGenerationAndEvicted() throws {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 2
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale)
        let width = max(1, Int(metrics.cellSize.width * CGFloat(Self.geometry.columns) * scale))
        let height = max(1, Int(metrics.cellSize.height * CGFloat(Self.geometry.rows) * scale))
        let texture = try #require(renderer.makeOffscreenTexture(width: width, height: height))

        let engine = try SSHTerminalEngine(geometry: .init(
            columns: Self.geometry.columns, rows: Self.geometry.rows,
            cellWidth: Int(metrics.cellSize.width * scale), cellHeight: Int(metrics.cellSize.height * scale)
        )) { _ in }
        engine.receive(kitty("a=T,f=32,s=4,v=4,i=6,c=4,r=2", payload: rgbaPayload(Array(repeating: Pixel(red: 0x20, green: 0x80, blue: 0xE0), count: 16))))

        func encode(fullRebuild: Bool) -> SSHTerminalMetalFrameCost {
            renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: fullRebuild
            )
        }

        let first = encode(fullRebuild: true)
        #expect(first.completed)
        #expect(first.imagePlacementCount == 1)
        #expect(first.imageUploadCount == 1, "the first frame uploads the image once")
        #expect(renderer.cachedImageCount == 1)

        // Steady state: no new upload, no pixel copy, still drawn.
        for _ in 0..<3 {
            let again = encode(fullRebuild: false)
            #expect(again.imageUploadCount == 0, "a frame in steady state must not re-upload")
            #expect(again.imagePlacementCount == 1)
        }
        #expect(renderer.cachedImageCount == 1)

        // Retransmission under the same id is a new generation: upload again.
        engine.receive(kitty("a=T,f=32,s=4,v=4,i=6,c=4,r=2", payload: rgbaPayload(Array(repeating: Pixel(red: 0xE0, green: 0x40, blue: 0x10), count: 16))))
        let replaced = encode(fullRebuild: false)
        #expect(replaced.imageUploadCount == 1)
        #expect(renderer.cachedImageCount == 1)

        // Deleted images leave the cache.
        engine.receive(kitty("a=d,d=A"))
        let cleared = encode(fullRebuild: true)
        #expect(cleared.imagePlacementCount == 0)
        #expect(renderer.cachedImageCount == 0)
    }

    @Test func unchangedFramesDoNotReiteratePlacements() throws {
        let engine = try engine()
        engine.receive(kitty("a=T,f=32,s=2,v=2,i=2,c=2,r=2", payload: rgbaPayload(Array(repeating: Pixel(red: 1, green: 2, blue: 3), count: 4))))
        _ = engine.frame()
        let reads = engine.kittyPlacementReadCount
        #expect(reads > 0)
        _ = engine.frame()
        _ = engine.frame()
        #expect(engine.kittyPlacementReadCount == reads, "an unchanged screen re-reads no placements")

        engine.scroll(rows: -1)
        _ = engine.frame()
        #expect(engine.kittyPlacementReadCount > reads, "a viewport move re-resolves geometry")
    }

    // MARK: - Frame budget

    /// A host printing thousands of 1x1 pictures. Packing used to walk every
    /// image for every layer against every placement (quadratic) and give each
    /// image its own texture and draw call; the caps keep one frame bounded.
    /// Every picture is pinned to the top-left cell, so all 10,000 placements are
    /// on screen at once and the packer really sees them.
    @Test func manyTinyImagesStayWithinTheFrameBudget() throws {
        let harness = try renderHarness(columns: 24, rows: 4)
        let home = Data("\u{1b}[1;1H".utf8)
        for index in 0..<10_000 {
            harness.engine.receive(home + kitty(
                "a=T,f=32,s=1,v=1,i=\(index + 1),c=1,r=1",
                payload: rgbaPayload([Pixel(red: 0x20, green: 0x80, blue: 0xE0)])
            ))
        }
        let snapshot = try #require(harness.engine.frame().kitty)
        #expect(snapshot.placements.count == 10_000, "every picture is on screen")
        #expect(snapshot.images.count == 10_000)

        let cost = harness.encode(fullRebuild: true)
        #expect(cost.completed)
        #expect(cost.imagePlacementCount > 0)
        #expect(
            cost.imagePlacementCount <= SSHTerminalMetalRenderer.maxKittyPlacementsPerFrame,
            "the placement cap bounds one frame's draw calls"
        )
        #expect(
            harness.renderer.cachedImageCount <= SSHTerminalMetalRenderer.maxKittyImagesPerFrame,
            "the image cap bounds the textures one frame uploads"
        )
        #expect(
            harness.renderer.cachedImageBytes <= SSHTerminalKittyGraphics.imageStorageLimitBytes,
            "textures stay inside the store budget"
        )
        #expect(harness.renderer.cachedImageBytes > 0, "the budget counts real texture bytes")

        // The caps are stable: a second frame re-draws the same bounded set.
        let again = harness.encode(fullRebuild: false)
        #expect(again.imagePlacementCount == cost.imagePlacementCount)
        #expect(again.imageUploadCount == 0, "the bounded set is already uploaded")
    }

    /// Three RGB pictures that fit libghostty's 64 MB store but expand past it as
    /// RGBA textures. The texture budget is sized from what the store can produce,
    /// so they upload once and stay: the old budget evicted them the same frame it
    /// drew them and copied them again on every redraw.
    @Test func largeRGBImagesAreNotReuploadedAfterWarmup() throws {
        let width = 3_000
        let height = 2_000
        // 18 MB each as RGB, 24 MB each as an RGBA texture: 54 MB stored, 72 MB of
        // textures, which the store's own 64 MB could never hold.
        let payload = Self.solidRGBZlib(width: width, height: height, value: 0x40)
        #expect(payload.count < 200_000, "the payload stays tiny however large the picture")
        let harness = try renderHarness(columns: 8, rows: 4)
        let home = Data("\u{1b}[1;1H".utf8)
        for index in 0..<3 {
            harness.engine.receive(home + kitty(
                "a=T,f=24,s=\(width),v=\(height),o=z,i=\(index + 1),c=4,r=2",
                payload: payload
            ))
        }
        let snapshot = try #require(harness.engine.frame().kitty)
        #expect(snapshot.images.count == 3)

        let warmup = harness.encode(fullRebuild: true)
        #expect(warmup.completed)
        #expect(warmup.imagePlacementCount == 3)
        #expect(warmup.imageUploadCount == 3)
        #expect(harness.renderer.cachedImageCount == 3)
        #expect(
            harness.renderer.cachedImageBytes > SSHTerminalKittyGraphics.imageStorageLimitBytes,
            "as textures these pictures are bigger than the store holding them"
        )

        for _ in 0..<3 {
            let redraw = harness.encode(fullRebuild: false)
            #expect(redraw.imagePlacementCount == 3)
            #expect(redraw.imageUploadCount == 0, "a picture inside the texture budget is never re-uploaded")
        }
        #expect(harness.renderer.imageEvictionCount == 0)
    }

    /// Pictures that individually fit the budget but together do not: the frame
    /// draws what it can, keeps what it drew, and remembers the refusals so a
    /// redraw neither evicts the picture on screen nor rebuilds the rest. Room is
    /// made before Metal allocates, so a picture the budget refuses costs no
    /// allocation at all.
    @Test func budgetOverflowIsRetriedButNeverEvictsWhatItDrew() throws {
        // One 256x256 RGBA picture is exactly the whole budget this renderer is
        // given, so the first fits and the next three cannot. A full budget is a
        // property of the frame, not of the picture, so the three are tried again
        // on later frames while the picture on screen stays put.
        let limit = 256 * 256 * 4
        let harness = try renderHarness(columns: 8, rows: 1, kittyTextureLimit: limit)
        let home = Data("\u{1b}[1;1H".utf8)
        let payload = rgbaPayload(Array(repeating: Pixel(red: 0x10, green: 0x20, blue: 0x30), count: 256 * 256))
        for index in 0..<4 {
            harness.engine.receive(home + kitty(
                "a=T,f=32,s=256,v=256,i=\(index + 1),c=2,r=1", payload: payload
            ))
        }

        let first = harness.encode(fullRebuild: true)
        #expect(first.completed)
        #expect(first.imagePlacementCount == 1, "only the picture that fits is drawn")
        #expect(harness.renderer.cachedImageCount == 1)
        #expect(harness.renderer.cachedImageBytes <= limit)
        #expect(harness.renderer.imageEvictionCount == 0, "nothing drawn this frame is evicted")
        let firstCreations = harness.renderer.imageUploadCount
        #expect(firstCreations == 1, "a picture the budget refuses is never built first")

        let second = harness.encode(fullRebuild: false)
        #expect(second.imagePlacementCount == 1, "the picture on screen is never evicted")
        #expect(harness.renderer.cachedImageCount == 1)
        #expect(harness.renderer.imageEvictionCount == 0)
        #expect(
            harness.renderer.imageUploadCount == firstCreations,
            "a full budget is retried on a later frame without creating a texture"
        )
    }

    /// A picture larger than the whole budget is refused for that generation
    /// before Metal builds it, so a redraw costs nothing instead of allocating and
    /// dropping it each time.
    @Test func oversizeImageIsRefusedBeforeItIsBuilt() throws {
        let harness = try renderHarness(columns: 8, rows: 4, kittyTextureLimit: 256 * 1024)
        let payload = rgbaPayload(Array(repeating: Pixel(red: 9, green: 9, blue: 9), count: 512 * 512))
        harness.engine.receive(kitty("a=T,f=32,s=512,v=512,i=71,c=2,r=1", payload: payload))
        let first = harness.encode(fullRebuild: true)
        #expect(first.completed)
        #expect(first.imagePlacementCount == 0, "a picture past the budget is not drawn")
        #expect(harness.renderer.imageUploadCount == 0, "it is refused before a texture is made")
        for _ in 0..<3 {
            let redraw = harness.encode(fullRebuild: false)
            #expect(redraw.imagePlacementCount == 0)
        }
        #expect(harness.renderer.imageUploadCount == 0)
        #expect(harness.renderer.cachedImageCount == 0)
    }

    // MARK: - Memory pressure

    /// A texture Metal refused is retried on a doubling wait, not on every frame:
    /// under memory pressure each attempt is a full-size allocation that fails
    /// again, and one per frame at frame rate is what kept the app there.
    @Test func textureAllocationBackoffDoublesToACap() {
        var backoff = SSHTerminalKittyTextureBackoff(generation: 3)
        var tick: UInt64 = 100
        var skipped: [Int] = []
        for _ in 0..<9 {
            backoff.recordFailure(frameTick: tick)
            // Frames between this failure and the next attempt.
            skipped.append(Int(backoff.retryTick - tick) - 1)
            tick = backoff.retryTick
        }
        #expect(skipped == [1, 2, 4, 8, 16, 32, 64, 64, 64])
        #expect(SSHTerminalKittyTextureBackoff.skipFrames(afterFailures: 0) == 0)
    }

    /// The same schedule measured through real frames: one allocation attempt per
    /// wait, doubling to the cap, and nothing drawn while it fails.
    @Test func failedTextureAllocationIsRetriedOnADoublingWait() throws {
        let probe = KittyTextureAllocationProbe()
        probe.fails = true
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 1
        let cellWidth = Int(metrics.cellSize.width * scale)
        let cellHeight = Int(metrics.cellSize.height * scale)
        let renderer = try SSHTerminalMetalRenderer(
            pipeline: try SSHTerminalMetalPipeline.shared(), metrics: metrics, scale: scale,
            kittyTextureAllocate: probe.allocate
        )
        let texture = try #require(renderer.makeOffscreenTexture(
            width: max(1, cellWidth * 8), height: max(1, cellHeight)
        ))
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: 8, rows: 1, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        engine.receive(kitty(
            "a=T,f=32,s=8,v=8,i=31,c=2,r=1",
            payload: rgbaPayload(Array(repeating: Pixel(red: 0x30, green: 0x60, blue: 0x90), count: 64))
        ))

        var attemptFrames: [Int] = []
        for frame in 1...210 {
            probe.frame = frame
            let before = probe.attempts
            let cost = renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: false
            )
            #expect(cost.completed)
            #expect(cost.imagePlacementCount == 0, "a picture with no texture does not draw")
            #expect(probe.attempts - before <= 1, "one frame makes at most one attempt")
            if probe.attempts > before { attemptFrames.append(frame) }
        }

        // Attempt, then skip 1 frame, 2, 4 ... 64, and 64 again at the cap.
        #expect(attemptFrames.prefix(9) == [1, 3, 6, 11, 20, 37, 70, 135, 200])
        let gaps = zip(attemptFrames, attemptFrames.dropFirst()).map { $1 - $0 - 1 }
        #expect(gaps.prefix(8) == [1, 2, 4, 8, 16, 32, 64, 64])
        #expect(probe.attempts == attemptFrames.count, "no attempt escapes the schedule")
        #expect(renderer.imageUploadCount == 0)
        #expect(renderer.cachedImageCount == 0, "a refused allocation caches nothing")
    }

    /// The wait belongs to one image generation: a retransmission is tried on the
    /// next frame instead of waiting out the old schedule, and the first failure
    /// after a successful upload starts again at one skipped frame.
    @Test func textureBackoffResetsWhenTheImageIsRetransmittedOrUploads() throws {
        let probe = KittyTextureAllocationProbe()
        probe.fails = true
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 1
        let cellWidth = Int(metrics.cellSize.width * scale)
        let cellHeight = Int(metrics.cellSize.height * scale)
        let renderer = try SSHTerminalMetalRenderer(
            pipeline: try SSHTerminalMetalPipeline.shared(), metrics: metrics, scale: scale,
            kittyTextureAllocate: probe.allocate
        )
        let texture = try #require(renderer.makeOffscreenTexture(
            width: max(1, cellWidth * 8), height: max(1, cellHeight)
        ))
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: 8, rows: 1, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        func transmit(_ red: UInt8) {
            engine.receive(kitty(
                "a=T,f=32,s=8,v=8,i=9,c=2,r=1",
                payload: rgbaPayload(Array(repeating: Pixel(red: red, green: 0x20, blue: 0x40), count: 64))
            ))
        }
        var frame = 0
        func encode() -> SSHTerminalMetalFrameCost {
            frame += 1
            probe.frame = frame
            return renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: false
            )
        }

        transmit(0x80)
        #expect(encode().imagePlacementCount == 0) // frame 1: attempt 1, fails
        #expect(encode().imagePlacementCount == 0) // frame 2: skipped
        #expect(encode().imagePlacementCount == 0) // frame 3: attempt 2, fails
        #expect(probe.attempts == 2, "two failures wait two frames") // next attempt is frame 6
        probe.fails = false
        #expect(encode().imagePlacementCount == 0) // frame 4: skipped
        #expect(encode().imagePlacementCount == 0) // frame 5: skipped
        #expect(encode().imagePlacementCount == 1) // frame 6: attempt 3 uploads
        #expect(renderer.imageUploadCount == 1)

        // A retransmission is a new generation: no inherited wait, and with the
        // allocator failing again it starts over at one skipped frame. The cached
        // texture of the old generation is gone, so nothing draws until an upload
        // succeeds.
        probe.fails = true
        transmit(0x81)
        #expect(encode().imagePlacementCount == 0) // frame 7: attempt 4, fails
        #expect(probe.attempts == 4, "a new generation is tried on the next frame")
        #expect(encode().imagePlacementCount == 0) // frame 8: skipped
        #expect(encode().imagePlacementCount == 0) // frame 9: attempt 5, fails
        #expect(probe.attempts == 5, "a new schedule starts at one skipped frame")
        #expect(probe.attemptFrames == [1, 3, 6, 7, 9])
    }

    /// RGB expands to RGBA one row at a time into a reused buffer instead of
    /// allocating and writing a full-size copy. The rows still have to land in the
    /// right place: each band of the picture keeps its own colour.
    @Test func rgbRowsExpandIntoTheRightTextureRows() throws {
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 1
        let cellWidth = Int(metrics.cellSize.width * scale)
        let cellHeight = Int(metrics.cellSize.height * scale)
        let renderer = try SSHTerminalMetalRenderer(
            pipeline: try SSHTerminalMetalPipeline.shared(), metrics: metrics, scale: scale
        )
        let width = cellWidth * 2
        let height = 16
        let texture = try #require(renderer.makeOffscreenTexture(width: cellWidth * 4, height: cellHeight))
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: 4, rows: 1, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        // Four bands of four rows: red, green, blue, white, sent as 3 bytes each.
        let bands: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
        var rgb = [UInt8]()
        for y in 0..<height {
            let band = bands[y * bands.count / height]
            for _ in 0..<width { rgb += [band.0, band.1, band.2] }
        }
        engine.receive(kitty(
            "a=T,f=24,s=\(width),v=\(height),i=15,c=2,r=1",
            payload: Data(rgb).base64EncodedString()
        ))
        let cost = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(0, 0, 0, 0),
            texture: texture, waitUntilCompleted: true, fullRebuild: true
        )
        #expect(cost.completed)
        #expect(cost.imagePlacementCount == 1, "the RGB picture draws")
        #expect(cost.imageUploadCount == 1)

        var bytes = [UInt8](repeating: 0, count: cellWidth * 4 * cellHeight * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: cellWidth * 4 * 4,
                from: MTLRegionMake2D(0, 0, cellWidth * 4, cellHeight), mipmapLevel: 0
            )
        }
        // 1:1 placement: destination y maps to the same source row.
        func pixel(_ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let x = width / 4
            let offset = (y * cellWidth * 4 + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        for (index, band) in bands.enumerated() {
            // Centre of the band, away from the linear filter's seam.
            let y = (index * 4 + 2) * cellHeight / height
            let sampled = pixel(y)
            #expect(sampled.a == 255, "the expanded rows are opaque")
            #expect(Int(sampled.r) == Int(band.0), "row \(index) keeps its red")
            #expect(Int(sampled.g) == Int(band.1), "row \(index) keeps its green")
            #expect(Int(sampled.b) == Int(band.2), "row \(index) keeps its blue")
        }
    }

    @Test func imageScrolledOutOfViewKeepsItsTexture() throws {
        let harness = try renderHarness(columns: 8, rows: 4)
        harness.engine.receive(Data((0..<40).map { "line \($0)\r\n" }.joined().utf8))
        harness.engine.receive(Data("\u{1b}[2;1H".utf8))
        harness.engine.receive(kitty(
            "a=T,f=32,s=2,v=2,i=6,c=2,r=1",
            payload: rgbaPayload(Array(repeating: Pixel(red: 1, green: 2, blue: 3), count: 4))
        ))
        #expect(harness.encode(fullRebuild: true).imageUploadCount == 1)
        let uploads = harness.renderer.imageUploadCount

        // Far enough into history that the pinned picture is off the viewport.
        harness.engine.scroll(rows: -20)
        let away = harness.encode(fullRebuild: true)
        #expect(away.imagePlacementCount == 0)
        #expect(harness.renderer.cachedImageCount == 1, "the image is stored, not deleted")
        #expect(harness.renderer.imageEvictionCount == 0, "a viewport move evicts nothing")
        #expect(harness.renderer.imageUploadCount == uploads)

        harness.engine.scroll(rows: 20)
        let back = harness.encode(fullRebuild: true)
        #expect(back.imagePlacementCount == 1, "scrolling back draws it again")
        #expect(harness.renderer.imageUploadCount == uploads, "coming back copies no pixels")

        // A real delete is what evicts the texture.
        harness.engine.receive(kitty("a=d,d=A"))
        let deleted = harness.encode(fullRebuild: true)
        #expect(deleted.imagePlacementCount == 0)
        #expect(harness.renderer.cachedImageCount == 0)
    }

    /// The alternate screen has its own image store. Leaving the picture behind
    /// on the main screen and coming back is not a deletion either.
    @Test func altScreenToggleKeepsTheMainScreenTexture() throws {
        let harness = try renderHarness(columns: 8, rows: 4)
        harness.engine.receive(kitty(
            "a=T,f=32,s=2,v=2,i=7,c=2,r=1",
            payload: rgbaPayload(Array(repeating: Pixel(red: 4, green: 5, blue: 6), count: 4))
        ))
        #expect(harness.encode(fullRebuild: true).imageUploadCount == 1)
        let uploads = harness.renderer.imageUploadCount

        harness.engine.receive(Data("\u{1b}[?1049h".utf8))
        let alt = harness.encode(fullRebuild: true)
        #expect(alt.imagePlacementCount == 0)

        harness.engine.receive(Data("\u{1b}[?1049l".utf8))
        let main = harness.encode(fullRebuild: true)
        #expect(main.imagePlacementCount == 1, "the picture is back")
        #expect(harness.renderer.imageUploadCount == uploads, "the same texture is reused")
    }

    @MainActor
    private struct RenderHarness {
        let engine: SSHTerminalEngine
        let renderer: SSHTerminalMetalRenderer
        let texture: MTLTexture

        func encode(fullRebuild: Bool) -> SSHTerminalMetalFrameCost {
            encode(fullRebuild: fullRebuild, with: renderer, texture: texture)
        }

        /// Encode through another renderer, the way a view rebuilt with an empty
        /// texture cache would.
        func encode(
            fullRebuild: Bool, with renderer: SSHTerminalMetalRenderer, texture: MTLTexture
        ) -> SSHTerminalMetalFrameCost {
            renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: fullRebuild
            )
        }
    }

    private func renderHarness(
        columns: Int, rows: Int, kittyTextureLimit: Int = SSHTerminalKittyTextureCache.limitBytes
    ) throws -> RenderHarness {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 2
        let renderer = try SSHTerminalMetalRenderer(
            pipeline: pipeline, metrics: metrics, scale: scale, kittyTextureLimit: kittyTextureLimit
        )
        let width = max(1, Int(metrics.cellSize.width * CGFloat(columns) * scale))
        let height = max(1, Int(metrics.cellSize.height * CGFloat(rows) * scale))
        let texture = try #require(renderer.makeOffscreenTexture(width: width, height: height))
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: columns, rows: rows,
            cellWidth: Int(metrics.cellSize.width * scale),
            cellHeight: Int(metrics.cellSize.height * scale)
        )) { _ in }
        return RenderHarness(engine: engine, renderer: renderer, texture: texture)
    }

    // MARK: - Drawn pixels

    @Test func imagePixelsReachTheGridInTheirLayer() throws {
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 2
        let cellWidth = Int(metrics.cellSize.width * scale)
        let cellHeight = Int(metrics.cellSize.height * scale)
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: 8, rows: 4, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        engine.setColors(
            foreground: .init(r: 255, g: 255, b: 255),
            background: .init(r: 0, g: 0, b: 0), dark: true
        )
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale)
        let width = max(1, Int(metrics.cellSize.width * CGFloat(8) * scale))
        let height = max(1, Int(metrics.cellSize.height * CGFloat(4) * scale))
        let texture = try #require(renderer.makeOffscreenTexture(width: width, height: height))

        func render() throws -> (bytes: [UInt8], width: Int, height: Int) {
            let cost = renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(0, 0, 0, 0),
                texture: texture, waitUntilCompleted: true, fullRebuild: true
            )
            #expect(cost.completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.getBytes(
                    base, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
                )
            }
            return (bytes, width, height)
        }

        // One opaque red pixel stretched over cell (2,1) and its right neighbour.
        engine.receive(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[H\u{1b}[2;3H".utf8))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=1,c=2,r=1", payload: rgbaPayload([Pixel(red: 255, green: 0, blue: 0)])))
        let shot = try render()
        // BGRA in memory (bgra8Unorm).
        let cellW: CGFloat = metrics.cellSize.width * scale
        let cellH: CGFloat = metrics.cellSize.height * scale
        func pixel(column: Int, row: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
            let x = min(shot.width - 1, Int((CGFloat(column) + 0.5) * cellW))
            let y = min(shot.height - 1, Int((CGFloat(row) + 0.5) * cellH))
            let offset = (y * shot.width + x) * 4
            return (shot.bytes[offset], shot.bytes[offset + 1], shot.bytes[offset + 2])
        }
        #expect(pixel(column: 2, row: 1).r > 200, "the image draws in its cell")
        #expect(pixel(column: 3, row: 1).r > 200, "a two-cell placement spans both cells")
        #expect(pixel(column: 0, row: 0).r < 40, "nothing draws outside the placement")
        #expect(pixel(column: 2, row: 2).r < 40, "the placement is one row tall")

        // The same cell with a glyph: above text hides it, below text does not.
        func glyphInkVisible(aboveText: Bool) throws -> Bool {
            let image = kitty(
                "a=T,f=32,s=1,v=1,i=2,c=1,r=1,z=\(aboveText ? 1 : -1)",
                payload: rgbaPayload([Pixel(red: 0, green: 0, blue: 255)])
            )
            engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[38;2;255;255;255mM\u{1b}[0m\u{1b}[1;1H".utf8))
            engine.receive(image)
            let shot = try render()
            // Sample the glyph area: white text over blue is not pure blue.
            for stepX in 0..<7 {
                for stepY in 0..<7 {
                    let fx: CGFloat = 0.2 + CGFloat(stepX) * 0.1
                    let fy: CGFloat = 0.2 + CGFloat(stepY) * 0.1
                    let x = min(shot.width - 1, Int(fx * cellW))
                    let y = min(shot.height - 1, Int(fy * cellH))
                    let offset = (y * shot.width + x) * 4
                    if shot.bytes[offset + 2] > 120 { return true } // red channel: glyph ink
                }
            }
            return false
        }
        let above = try glyphInkVisible(aboveText: true)
        #expect(!above, "an above-text image covers the glyph")
        let below = try glyphInkVisible(aboveText: false)
        #expect(below, "a below-text image leaves the glyph on top")
    }

    // MARK: - PNG decode limits

    /// Decoding is bounded from the header, before ImageIO copies a pixel: an
    /// 84 KB PNG that declares a 5000x5000 picture is 100 MB of RGBA, and the old
    /// path allocated that (plus ImageIO's own copy, plus libghostty's) first and
    /// only then discovered it did not fit the 64 MB store.
    @Test func pngDeclaringAHugeCanvasIsRefusedBeforeDecoding() throws {
        let bomb = Self.solidPNG(width: 5_000, height: 5_000)
        #expect(bomb.count < 200_000, "the payload itself is tiny")
        let source = try #require(CGImageSourceCreateWithData(bomb as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 5_000,
            "ImageIO accepts the declared canvas, so only the guard can refuse it"
        )

        #expect(
            SSHTerminalKittyPNGDecoder.allowedByteCount(width: 5_000, height: 5_000) == nil,
            "100 MB of RGBA does not fit the 64 MB budget"
        )
        #expect(SSHTerminalKittyPNGDecoder.allowedByteCount(width: 4_000, height: 4_000) == 64_000_000)
        #expect(
            SSHTerminalKittyPNGDecoder.allowedByteCount(width: 10_001, height: 1) == nil,
            "a side past the dimension cap is refused even though it would fit"
        )
        #expect(
            SSHTerminalKittyPNGDecoder.allowedByteCount(width: Int.max, height: Int.max) == nil,
            "huge sides are refused, not wrapped or trapped on"
        )
        #expect(SSHTerminalKittyPNGDecoder.allowedByteCount(width: 0, height: 10) == nil)

        var replies = [Data]()
        let engine = try engine { replies.append($0) }
        engine.receive(kitty("a=T,f=100,i=12,c=2,r=2", payload: bomb.base64EncodedString()))
        #expect(engine.frame().kitty == nil, "nothing is stored")
        #expect(
            replies.map { String(decoding: $0, as: UTF8.self) }
                == ["\u{1b}_Gi=12;EINVAL: invalid data\u{1b}\\"]
        )
    }

    /// CGContext writes premultiplied pixels; the protocol's RGBA is straight, so
    /// the renderer's blending needs the alpha divided back out.
    @Test func semiTransparentPNGDecodesToStraightAlpha() throws {
        let pngData = try png(width: 2, height: 2, rows: [
            [Pixel(red: 255, green: 0, blue: 0, alpha: 128), Pixel(red: 0, green: 0, blue: 0, alpha: 0)],
            [Pixel(red: 255, green: 255, blue: 255), Pixel(red: 10, green: 20, blue: 30)],
        ])
        let engine = try engine()
        engine.receive(kitty("a=T,f=100,i=41,c=2,r=2", payload: pngData.base64EncodedString()))
        let frame = engine.frame()
        let snapshot = try #require(frame.kitty)
        let image = try #require(snapshot.images.first)
        let bytes = try pixelBytes(of: image, graphics: frame.kittyGraphics)
        #expect(bytes[3] == 128, "alpha survives the round trip")
        #expect(bytes[0] > 250, "unpremultiply restores the straight red channel")
        #expect(bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0, "a transparent pixel has no colour")
        #expect(bytes[8] == 255 && bytes[9] == 255 && bytes[10] == 255)
    }

    // MARK: - Synchronized output

    /// Mode 2026 holds the whole picture. An image that arrives inside a held
    /// frame must not draw over the text that frame is still showing, so the
    /// store's new generation waits for the release.
    @Test func heldSynchronizedOutputKeepsThePreviousSnapshot() throws {
        let engine = try engine()
        let white = rgbaPayload([Pixel(red: 255, green: 255, blue: 255)])
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=61,c=1,r=1", payload: white))
        let before = engine.frame()
        #expect(before.kitty?.placements.map(\.imageID) == [61])
        #expect(before.kittyGraphics != nil, "a live frame may read its store")

        engine.receive(Data("\u{1b}[?2026h".utf8))
        #expect(engine.renderHeld)
        engine.receive(kitty("a=d,d=i,i=61"))
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=62,c=1,r=1", payload: white))
        let held = engine.frame()
        #expect(held.kitty?.placements.map(\.imageID) == [61], "the held frame keeps the picture it drew")
        #expect(held.kitty?.storedImageIDs.contains(62) == false, "the new image waits for the release")
        #expect(held.kittyGraphics == nil, "a held frame gets no store handle to read")

        engine.receive(Data("\u{1b}[?2026l".utf8))
        #expect(!engine.renderHeld)
        let released = engine.frame()
        #expect(released.kitty?.placements.map(\.imageID) == [62], "the release shows the new picture")
    }

    /// A reset frees the alternate screen's image storage while a host still
    /// holds the frame (mode 2026 clears with the reset, so the host sets it
    /// again). A view rebuilt with an empty texture cache then asks for pixels it
    /// does not have: the held frame must hand the renderer no store handle, so
    /// nothing dereferences the freed store, and the picture has to come back from
    /// the live store after the release.
    @Test func heldFrameAcrossResetResolvesNothingFromTheOldStore() throws {
        let harness = try renderHarness(columns: 8, rows: 4)
        let white = rgbaPayload([Pixel(red: 200, green: 100, blue: 50)])
        harness.engine.receive(Data("\u{1b}[?1049h".utf8)) // alternate screen, then RIS frees it
        harness.engine.receive(kitty("a=T,f=32,s=1,v=1,i=81,c=1,r=1", payload: white))
        #expect(harness.encode(fullRebuild: true).imageUploadCount == 1)

        engineHold(harness)
        harness.engine.receive(Data("\u{1b}c".utf8)) // RIS
        #expect(!harness.engine.renderHeld, "a reset clears mode 2026")
        engineHold(harness)
        #expect(harness.engine.renderHeld)
        harness.engine.receive(kitty("a=T,f=32,s=1,v=1,i=82,c=1,r=1", payload: white))

        // The held frame still shows the picture from the store that is gone, and
        // carries no handle to it.
        let stale = harness.engine.frame()
        #expect(stale.kitty?.placements.map(\.imageID) == [81])
        #expect(stale.kittyGraphics == nil)

        // A renderer that was just created has no textures, so the held frame is
        // a cache miss against a store that may already be gone.
        let fresh = try SSHTerminalMetalRenderer(
            pipeline: try SSHTerminalMetalPipeline.shared(),
            metrics: SSHTerminalCellMetrics.codeFont(), scale: 2
        )
        let freshTexture = try #require(fresh.makeOffscreenTexture(
            width: max(1, Int(SSHTerminalCellMetrics.codeFont().cellSize.width * 16)),
            height: max(1, Int(SSHTerminalCellMetrics.codeFont().cellSize.height * 8))
        ))
        let held = harness.encode(fullRebuild: true, with: fresh, texture: freshTexture)
        #expect(held.completed)
        #expect(held.imageUploadCount == 0, "a held frame resolves no pixels")
        #expect(fresh.cachedImageCount == 0)

        harness.engine.receive(Data("\u{1b}[?2026l".utf8))
        let released = harness.engine.frame()
        #expect(!harness.engine.renderHeld)
        #expect(released.kittyGraphics != nil, "the release hands out the live store")
        let after = harness.encode(fullRebuild: true, with: fresh, texture: freshTexture)
        let snapshot = try #require(released.kitty)
        #expect(after.imageUploadCount == 1, "the picture is read from the current store")
        #expect(after.imagePlacementCount == 1)
        let image = try #require(snapshot.images.first)
        #expect(image.id == 82)
        #expect(try pixelBytes(of: image, graphics: released.kittyGraphics) == [200, 100, 50, 255])
    }

    private func engineHold(_ harness: RenderHarness) {
        harness.engine.receive(Data("\u{1b}[?2026h".utf8))
    }

    // MARK: - PNG fixture

    /// A PNG built the way a program on the host would: any row count, real
    /// color, sRGB.
    private func png(width: Int, height: Int, rows: [[Pixel]]) throws -> Data {
        var bytes = [UInt8]()
        for row in rows {
            for pixel in row { bytes += [pixel.red, pixel.green, pixel.blue, pixel.alpha] }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        // The bitmap context's image copies the buffer, so the bytes can go
        // out of scope here.
        let image = try #require(bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        })
        let data = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The stored pixels of one image, read through the same lazy lookup the
    /// renderer uses when it uploads.
    private func pixelBytes(
        of image: SSHTerminalKittyImage, graphics: GhosttyKittyGraphics?
    ) throws -> [UInt8] {
        let handle = try #require(graphics)
        let pixels = try #require(image.resolvePixels(handle))
        return Array(UnsafeBufferPointer(start: pixels.pointer, count: pixels.byteCount))
    }

    /// A solid RGB picture as the zlib payload `o=z` takes: tiny on the wire
    /// however many pixels it decodes to.
    private static func solidRGBZlib(width: Int, height: Int, value: UInt8) -> String {
        Data(zlibWrapped([UInt8](repeating: value, count: width * 3), rows: height))
            .base64EncodedString()
    }

    /// The zlib stream PNG and kitty's `o=z` both expect. Apple's
    /// `COMPRESSION_ZLIB` emits bare deflate blocks, so the two-byte header and
    /// the Adler-32 checksum of the uncompressed picture are added here. The
    /// checksum folds the row once and then applies the per-row recurrence, so a
    /// hundred-megabyte canvas costs no more than a single row.
    private static func zlibWrapped(_ row: [UInt8], rows: Int) -> [UInt8] {
        var rowSum: UInt64 = 0
        var rowPrefixSum: UInt64 = 0
        var prefix: UInt64 = 0
        for byte in row {
            prefix += UInt64(byte)
            rowSum += UInt64(byte)
            rowPrefixSum += prefix
        }
        var low: UInt64 = 1
        var high: UInt64 = 0
        let count = UInt64(row.count)
        for _ in 0..<rows {
            high = (high + count * low + rowPrefixSum) % 65521
            low = (low + rowSum) % 65521
        }
        let adler = UInt32((high << 16) | low)
        var out: [UInt8] = [0x78, 0x01]
        out += deflate(row, rows: rows)
        out += [
            UInt8(truncatingIfNeeded: adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
            UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler),
        ]
        return out
    }

    /// A valid PNG that declares `width`x`height` and holds one solid colour, built
    /// row by row through a real zlib stream. Whatever the canvas size, the file
    /// itself stays small: this is the shape of a decode bomb.
    private static func solidPNG(width: Int, height: Int, value: UInt8 = 0x40) -> Data {
        var header = [UInt8]()
        for field in [UInt32(width).bigEndian, UInt32(height).bigEndian] {
            withUnsafeBytes(of: field) { header += Array($0) }
        }
        header += [8, 2, 0, 0, 0] // 8-bit truecolour, deflate, adaptive filtering, no interlace
        var row = [UInt8](repeating: value, count: width * 3)
        row[0] = 0 // filter type 0 (None) for every row
        let compressed = zlibWrapped(row, rows: height)
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += pngChunk("IHDR", header)
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + 32 * 1024, compressed.count)
            bytes += pngChunk("IDAT", Array(compressed[offset..<end]))
            offset = end
        }
        bytes += pngChunk("IEND", [])
        return Data(bytes)
    }

    /// Deflate one row repeated `rows` times, feeding the same buffer so the
    /// fixture never holds the uncompressed picture in memory.
    private static func deflate(_ row: [UInt8], rows: Int) -> [UInt8] {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return [] }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var status = COMPRESSION_STATUS_OK
        row.withUnsafeBufferPointer { source in
            for _ in 0..<rows {
                stream.src_ptr = source.baseAddress!
                stream.src_size = source.count
                while true {
                    let produced = buffer.withUnsafeMutableBufferPointer { destination -> Int in
                        stream.dst_ptr = destination.baseAddress!
                        stream.dst_size = destination.count
                        status = compression_stream_process(&stream, 0)
                        return destination.count - stream.dst_size
                    }
                    output += buffer[0..<produced]
                    if stream.src_size == 0 && produced < buffer.count { break }
                }
            }
        }
        status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            let produced = buffer.withUnsafeMutableBufferPointer { destination -> Int in
                stream.dst_ptr = destination.baseAddress!
                stream.dst_size = destination.count
                status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                return destination.count - stream.dst_size
            }
            output += buffer[0..<produced]
        }
        return output
    }

    private static func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { out += Array($0) }
        let typeBytes = Array(type.utf8)
        out += typeBytes
        out += data
        withUnsafeBytes(of: crc32(typeBytes + data).bigEndian) { out += Array($0) }
        return out
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Stands in for Metal's texture allocator. A simulator never fails
/// `makeTexture`, so this is the only way to drive the memory-pressure path: it
/// records the frame of every attempt and can refuse them.
private final class KittyTextureAllocationProbe {
    var fails = false
    private(set) var attempts = 0
    private(set) var attemptFrames: [Int] = []
    /// Drawing frame the caller is encoding, recorded per attempt.
    var frame = 0

    func allocate(_ device: MTLDevice, _ descriptor: MTLTextureDescriptor) -> MTLTexture? {
        attempts += 1
        attemptFrames.append(frame)
        return fails ? nil : device.makeTexture(descriptor: descriptor)
    }
}
