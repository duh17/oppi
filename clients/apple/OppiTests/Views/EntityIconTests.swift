import Foundation
import Testing
import UIKit
@testable import Oppi

/// What `EntityIcon` draws for each entity: the chosen fallback symbol, an
/// Agent's Genmoji coming from the server's icon cache (and what a failed load
/// leaves behind), and the geometry a sandbox workspace needs for its mark. The
/// suite is serialized because the owner keeps one process-wide raster cache and
/// load counter.
@MainActor
@Suite(.serialized)
struct EntityIconTests {
    // MARK: - Fallbacks

    @Test func defaultWorkspaceDrawsTheGridSymbolNotAFolder() {
        let defaulted = EntityIcon.image(.workspace(nil, sandbox: false), size: 22)
        let grid = EntityIcon.image(.workspace(.symbol("square.grid.2x2"), sandbox: false), size: 22)
        let folder = EntityIcon.image(.workspace(.symbol("folder"), sandbox: false), size: 22)
        #expect(png(defaulted) == png(grid))
        #expect(png(defaulted) != png(folder))
    }

    @Test func agentWithoutAnIconDrawsPersonCropCircle() {
        let defaulted = EntityIcon.image(.agent(nil), size: 22)
        let expected = EntityIcon.image(.agent(.symbol("person.crop.circle")), size: 22)
        #expect(png(defaulted) == png(expected))
    }

    // MARK: - Artwork kinds

    @Test func emojiDrawsInsteadOfTheFallbackAtTheAskedSize() {
        let emoji = EntityIcon.image(.agent(.emoji("🐙")), size: 22)
        #expect(png(emoji) != png(EntityIcon.image(.agent(nil), size: 22)))
        // Drawn at the points the caller laid out, at the screen's own scale.
        #expect(abs(emoji.size.width - 22) < 0.5)
        #expect(abs(emoji.size.height - 22) < 0.5)
        #expect(emoji.scale >= 2)
    }

    @Test func providerMarksDifferByProvider() {
        let anthropic = EntityIcon.image(.provider("anthropic"), size: 18)
        let openai = EntityIcon.image(.provider("openai"), size: 18)
        #expect(png(anthropic) != png(openai))
        // A model asks for its provider's mark, so the pill and the breakdown agree.
        #expect(png(EntityIcon.image(.model("anthropic/claude-sonnet-4"), size: 18)) == png(anthropic))
    }

    @Test func providerMarkIsDrawnInBrandColour() throws {
        // No logo asset, so the monogram draws: it must be the brand colour, not
        // the plain comment grey the Usage mark used before.
        let monogram = EntityIcon.image(.provider("not-a-provider"), size: 16)
        let colour = try #require(averageColour(monogram))
        #expect(colour.a > 0.05)
        let spread = max(colour.r, max(colour.g, colour.b)) - min(colour.r, min(colour.g, colour.b))
        #expect(spread > 0.05)
    }

    // MARK: - Sandbox geometry

    @Test func sandboxMarkIsTheSizeItAlwaysWas() throws {
        let sandboxed = EntityIcon.image(.workspace(nil, sandbox: true), size: 16)
        // The mark's orange fill, inside its 1 pt background-coloured ring: the
        // disc itself is max(11, frame * 0.34) points across.
        let ring = try #require(warmestPixel(in: sandboxed))
        let fill = try #require(inBlob(sandboxed, near: ring, tolerance: 40))
        #expect(fill.width >= 8.5, "mark fill \(fill.width) pt across (disc 11 pt with its ring), rect \(fill)")
        #expect(fill.width <= 9.6)
        #expect(abs(fill.height - fill.width) <= 0.5, "the mark is a disc: \(fill)")
        // It sits against the frame's trailing edge, where main let it overhang.
        #expect(fill.maxX >= 14.5, "the mark ends at \(fill.maxX) pt in a 16 pt frame")
        #expect(fill.minY >= 4, "the mark starts at \(fill.minY) pt, in the bottom half")
    }

    /// The mark's own geometry, exactly as the drawer computes it, and the content
    /// box each caller lays out: a row keeps its glyph, the Guided pill steps back.
    @Test func geometryIsWhatMainDrew() {
        #expect(EntityIcon.sandboxMarkRect(inFrame: 16) == CGRect(x: 5, y: 5, width: 11, height: 11))
        let wide = EntityIcon.sandboxMarkRect(inFrame: 36)
        #expect(wide.width == 36 * 0.34)
        #expect(wide.maxX == 36, "the mark sits against the frame's corner")
        #expect(wide.maxY == 36)

        // The Guided pill draws a 12 pt icon in a 16 pt canvas; a row draws its
        // content box whole (IconChoiceUIView passes box(forGlyph: 24) = 30.77).
        #expect(EntityIcon.contentRect(inFrame: 16, content: 12) == CGRect(x: 2, y: 2, width: 12, height: 12))
        let rowGlyph = EntityIcon.box(forGlyph: 24)
        #expect(EntityIcon.contentRect(inFrame: 36, content: rowGlyph).width == rowGlyph)
        #expect(EntityIcon.contentRect(inFrame: 36, content: rowGlyph).minX == (36 - rowGlyph) / 2)
    }

    /// Main had two rules, and the content box is how each caller keeps its own:
    /// a row draws its glyph as large as it does plain, and the Guided pill steps
    /// a 12 pt icon back inside a 16 pt canvas to make room for the mark.
    @Test func eachCallerKeepsItsGlyphSizeWhenTheMarkAppears() {
        // A row: the content box is what draws, not the frame.
        let rowGlyph = EntityIcon.box(forGlyph: 24)
        let rowSandbox = EntityIcon.image(
            .workspace(.symbol("square.grid.2x2"), sandbox: true),
            size: 36,
            contentSize: rowGlyph
        )
        let narrower = EntityIcon.image(
            .workspace(.symbol("square.grid.2x2"), sandbox: true),
            size: 36,
            contentSize: 18
        )
        #expect(png(rowSandbox) != png(narrower), "a row's content box is what draws")
    }

    // MARK: - Pi mark

    /// The cached Pi mark is the style chosen now: switching Color to Monochrome
    /// and back never serves the other style's raster.
    @Test func piMarkFollowsTheChosenStyleThroughTheCache() {
        let defaults = UserDefaults.standard
        let key = AppPreferenceStore.Appearance.piIconStyleKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(PiIconStyle.color.rawValue, forKey: key)
        let color = EntityIcon.image(.pi, size: 22)
        defaults.set(PiIconStyle.monochrome.rawValue, forKey: key)
        let monochrome = EntityIcon.image(.pi, size: 22)
        #expect(png(monochrome) != png(color))
        #expect(png(monochrome) == png(PiAvatarRenderer.render(size: 22, style: .monochrome)))
        defaults.set(PiIconStyle.color.rawValue, forKey: key)
        #expect(png(EntityIcon.image(.pi, size: 22)) == png(color))
    }

    // MARK: - Genmoji

    @Test func genmojiDrawsTheFallbackUntilTheArtworkArrives() async throws {
        let assetId = "ia_" + String(repeating: "G", count: 43)
        let cache = IconAssetCache(
            fetch: { _ in Data([1, 2, 3]) },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        let genmoji = IconEntity.agent(.genmoji(assetId: assetId, contentDescription: "Octopus"))

        let before = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(before) == png(EntityIcon.image(.agent(nil), size: 22)))

        try await waitForLoad(since: EntityIcon.loadGeneration)

        let after = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(after) != png(before))
        let colour = try #require(averageColour(after))
        #expect(colour.r > colour.g)
        #expect(colour.b > colour.g)
    }

    /// A Genmoji that cannot be fetched leaves its fallback up: no redraw, no
    /// second fetch, whatever asks again.
    @Test func failedGenmojiLoadLeavesTheFallbackFinal() async throws {
        let assetId = "ia_" + String(repeating: "F", count: 43)
        let fetches = FetchCounter()
        let cache = IconAssetCache(
            fetch: { requested in
                await fetches.record(requested)
                throw APIError.server(status: 404, message: "no such icon")
            },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        let genmoji = IconEntity.agent(.genmoji(assetId: assetId, contentDescription: "Octopus"))
        let generation = EntityIcon.loadGeneration

        let first = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(first) == png(EntityIcon.image(.agent(nil), size: 22)))

        // Let the failing load finish.
        for _ in 0..<100 where await fetches.count() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fetches.count() == 1)
        #expect(EntityIcon.loadGeneration == generation, "a failed load announces nothing")

        // The next pass draws the same fallback and does not fetch again.
        let second = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(second) == png(first))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fetches.count() == 1, "a failed asset is not fetched a second time")
    }

    // MARK: - Helpers

    /// Waits for the owner to announce artwork that arrived after `generation`.
    private func waitForLoad(since generation: Int) async throws {
        for _ in 0..<200 where EntityIcon.loadGeneration == generation {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(EntityIcon.loadGeneration > generation)
    }

    private func png(_ image: UIImage) -> Data {
        image.pngData() ?? Data()
    }

    private func averageColour(_ image: UIImage) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        let grid = pixelGrid(image)
        guard !grid.pixels.isEmpty else { return nil }
        let count = CGFloat(grid.pixels.count)
        return (
            grid.pixels.reduce(0) { $0 + CGFloat($1.0) } / count / 255,
            grid.pixels.reduce(0) { $0 + CGFloat($1.1) } / count / 255,
            grid.pixels.reduce(0) { $0 + CGFloat($1.2) } / count / 255,
            grid.pixels.reduce(0) { $0 + CGFloat($1.3) } / count / 255
        )
    }

    /// The most orange pixel in the bottom-trailing quadrant: the sandbox mark's
    /// fill, whatever the theme's exact orange is.
    private func warmestPixel(in image: UIImage) -> (UInt8, UInt8, UInt8, UInt8)? {
        let grid = pixelGrid(image)
        var best: (UInt8, UInt8, UInt8, UInt8)?
        var bestWarmth = 40
        for y in (grid.height / 2)..<grid.height {
            for x in (grid.width / 2)..<grid.width {
                let pixel = grid.pixels[y * grid.width + x]
                guard pixel.3 > 200 else { continue }
                let warmth = Int(pixel.0) - Int(pixel.2)
                if warmth > bestWarmth {
                    bestWarmth = warmth
                    best = pixel
                }
            }
        }
        return best
    }

    /// The bounding box of the pixels close to `pixel`, in image points.
    private func inBlob(
        _ image: UIImage,
        near pixel: (UInt8, UInt8, UInt8, UInt8),
        tolerance: Int
    ) -> CGRect? {
        let grid = pixelGrid(image)
        var minX = grid.width
        var minY = grid.width
        var maxX = -1
        var maxY = -1
        for (index, other) in grid.pixels.enumerated() {
            guard other.3 > 200,
                  abs(Int(other.0) - Int(pixel.0)) < tolerance,
                  abs(Int(other.1) - Int(pixel.1)) < tolerance,
                  abs(Int(other.2) - Int(pixel.2)) < tolerance else { continue }
            let x = index % grid.width
            let y = index / grid.width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / grid.scale,
            y: CGFloat(minY) / grid.scale,
            width: CGFloat(maxX - minX + 1) / grid.scale,
            height: CGFloat(maxY - minY + 1) / grid.scale
        )
    }

    /// Pixels and their own dimensions: the CGImage's, never the point size times a
    /// scale, which can round to a different count.
    private struct PixelGrid {
        let pixels: [(UInt8, UInt8, UInt8, UInt8)]
        let width: Int
        let height: Int
        let scale: CGFloat
    }

    private func pixelGrid(_ image: UIImage) -> PixelGrid {
        guard let cgImage = image.cgImage else {
            return PixelGrid(pixels: [], width: 0, height: 0, scale: image.scale)
        }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return PixelGrid(pixels: [], width: width, height: height, scale: image.scale)
        }
        let pixels = stride(from: 0, to: bytes.count, by: 4).map { offset in
            (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        return PixelGrid(pixels: pixels, width: width, height: height, scale: image.scale)
    }

    private static func solid(_ colour: UIColor, side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private actor FetchCounter {
        private var ids: [String] = []

        func record(_ assetId: String) { ids.append(assetId) }

        func count() -> Int { ids.count }
    }
}
