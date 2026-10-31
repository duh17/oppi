import Foundation
import Testing
import UIKit
@testable import Oppi

/// What `EntityIcon` draws for each entity: the fallback symbol Chen chose, an
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
        // The mark's disc is the widest run of ink in the bottom half: the mark
        // paints over the glyph, so its centre row measures the disc itself.
        let diameter = longestBottomRun(sandboxed)
        // Main drew max(11, frame * 0.34) points.
        #expect(diameter >= 10.5, "mark \(diameter) pt across, image \(sandboxed.size) @\(sandboxed.scale)")
        #expect(diameter <= 13)
    }

    @Test func sandboxIconIsDrawnSmallerThanAPlainOne() {
        // The icon steps back to leave the mark its corner.
        let plain = EntityIcon.image(.workspace(.symbol("square.grid.2x2"), sandbox: false), size: 16)
        let sandboxed = EntityIcon.image(.workspace(.symbol("square.grid.2x2"), sandbox: true), size: 16)
        let plainTop = inkTop(plain, scale: plain.scale)
        let sandboxTop = inkTop(sandboxed, scale: sandboxed.scale)
        #expect(plainTop < sandboxTop, "the plain icon draws bigger than the sandboxed one")
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
        let pixels = rgbaPixels(image)
        guard !pixels.isEmpty else { return nil }
        let count = CGFloat(pixels.count)
        return (
            pixels.reduce(0) { $0 + CGFloat($1.0) } / count / 255,
            pixels.reduce(0) { $0 + CGFloat($1.1) } / count / 255,
            pixels.reduce(0) { $0 + CGFloat($1.2) } / count / 255,
            pixels.reduce(0) { $0 + CGFloat($1.3) } / count / 255
        )
    }

    /// The widest horizontal run of ink in the bottom half of the image, in
    /// points: a sandbox mark paints over whatever is under it.
    private func longestBottomRun(_ image: UIImage) -> CGFloat {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        let pixels = rgbaPixels(image)
        var longest = 0
        for y in (height / 2)..<height {
            var right = -1
            for column in stride(from: width - 1, through: 0, by: -1)
            where pixels[y * width + column].3 > 200 {
                right = column
                break
            }
            guard right >= 0 else { continue }
            var left = right
            while left > 0, pixels[y * width + left - 1].3 > 200 {
                left -= 1
            }
            longest = max(longest, right - left + 1)
        }
        return CGFloat(longest) / image.scale
    }
    /// The first row with a visibly drawn pixel, in image points.
    private func inkTop(_ image: UIImage, scale: CGFloat) -> CGFloat {
        let width = Int(image.size.width * scale)
        for (index, pixel) in rgbaPixels(image).enumerated() where pixel.3 > 128 {
            return CGFloat(index / width) / scale
        }
        return image.size.height
    }

    private func rgbaPixels(_ image: UIImage) -> [(UInt8, UInt8, UInt8, UInt8)] {
        guard let cgImage = image.cgImage else { return [] }
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
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
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
