import CoreGraphics
import Foundation
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
        let pixels = try #require(image.pixels)
        #expect(Array(UnsafeBufferPointer(start: pixels, count: image.byteCount)) == [0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF])
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

        let kitty = try #require(engine.frame().kitty)
        let image = try #require(kitty.images.first)
        #expect(image.width == 2 && image.height == 2)
        #expect(image.format == .rgba)
        let pixels = try #require(image.pixels)
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 16)) == [
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
        #expect(engine.frame().kitty == nil)
    }

    @Test func retransmittingAnImageReplacesItsPixels() throws {
        let engine = try engine()
        engine.receive(kitty("a=T,f=32,s=1,v=1,i=8,c=1,r=1", payload: rgbaPayload([Pixel(red: 1, green: 1, blue: 1)])))
        let first = try #require(engine.frame().kitty?.images.first)
        let firstGeneration = first.generation

        engine.receive(kitty("a=T,f=32,s=1,v=1,i=8,c=1,r=1", payload: rgbaPayload([Pixel(red: 9, green: 9, blue: 9)])))
        let second = try #require(engine.frame().kitty?.images.first)
        #expect(second.generation != firstGeneration)
        let pixels = try #require(second.pixels)
        #expect(pixels[0] == 9)
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
}
