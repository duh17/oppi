import Foundation
import Testing
import UIKit
@testable import Oppi

/// What `EntityIcon` draws for each entity: the fallback symbol Chen chose, an
/// Agent's Genmoji coming from the server's icon cache, and the menu behaviour
/// (always-original artwork, the checkmark on `state`). The suite is serialized
/// because the owner keeps one process-wide raster cache and load counter.
@MainActor
@Suite(.serialized)
struct EntityIconTests {
    // MARK: - Fallbacks

    @Test func fallbackSymbolPerEntity() {
        #expect(EntityIcon.fallbackSymbol(.agent(nil)) == "person.crop.circle")
        #expect(EntityIcon.fallbackSymbol(.agent(.defaultValue)) == "person.crop.circle")
        #expect(EntityIcon.fallbackSymbol(.workspace(nil, sandbox: false)) == "square.grid.2x2")
        #expect(EntityIcon.fallbackSymbol(.workspace(.emoji("🌊"), sandbox: true)) == "square.grid.2x2")
        #expect(EntityIcon.fallbackSymbol(.pi) == "p.circle.fill")
        #expect(EntityIcon.fallbackSymbol(.provider("anthropic")) == "cpu")
        #expect(EntityIcon.fallbackSymbol(.model("anthropic/claude")) == "cpu")
        #expect(EntityIcon.fallbackSymbol(.server("server-1", .cube)) == ServerBadgeIcon.cube.symbolName)
    }

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

    @Test func piDrawsTheAvatar() {
        let pi = EntityIcon.image(.pi, size: 22)
        #expect(png(pi) == png(PiAvatarRenderer.render(size: 22)))
        #expect(png(pi) != png(EntityIcon.image(.agent(nil), size: 22)))
    }

    // MARK: - Artwork kinds

    @Test func emojiDrawsInsteadOfTheFallbackAtTheAskedSize() {
        let emoji = EntityIcon.image(.agent(.emoji("🐙")), size: 22)
        #expect(png(emoji) != png(EntityIcon.image(.agent(nil), size: 22)))
        // Rastered at twice the points for a menu that scales it down, but drawn
        // at the points the caller laid out.
        #expect(abs(emoji.size.width - 22) < 0.5)
        #expect(abs(emoji.size.height - 22) < 0.5)
    }

    @Test func sandboxWorkspaceCarriesTheLockMark() {
        let plain = EntityIcon.image(.workspace(nil, sandbox: false), size: 22)
        let sandboxed = EntityIcon.image(.workspace(nil, sandbox: true), size: 22)
        #expect(png(plain) != png(sandboxed))
        #expect(abs(sandboxed.size.width - 22) < 0.5)
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

    // MARK: - Menus

    @Test func imagesKeepTheirColoursInAMenu() {
        for entity in [
            IconEntity.agent(nil), .agent(.emoji("🐙")), .pi, .workspace(nil, sandbox: false),
            .provider("openai"), .model("openai/gpt-5"), .server("server-1", .atom),
        ] {
            #expect(EntityIcon.image(entity, size: 22).renderingMode == .alwaysOriginal)
        }
    }

    @Test func selectedChoiceUsesTheMenusOwnCheckmark() {
        let action = UIAction.choice("Agent", .agent(.emoji("🐙")), selected: true, assets: nil, id: "menu.agent") {}
        #expect(action.state == .on)
        #expect(action.identifier.rawValue == "menu.agent")
        #expect(action.image.map(png) == png(EntityIcon.image(.agent(.emoji("🐙")), size: 22)))

        let unselected = UIAction.choice("Agent", .agent(nil), selected: false, assets: nil) {}
        #expect(unselected.state == .off)
        #expect(unselected.image != nil)
    }

    // MARK: - Genmoji

    @Test func genmojiDrawsTheFallbackUntilTheArtworkIsCached() async throws {
        let assetId = "ia_" + String(repeating: "G", count: 43)
        let cache = IconAssetCache(
            fetch: { _ in Data([1, 2, 3]) },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        let genmoji = IconEntity.agent(.genmoji(assetId: assetId, contentDescription: "Octopus"))

        let before = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(before) == png(EntityIcon.image(.agent(nil), size: 22)))
        #expect(cache.cachedImage(assetId: assetId, size: 44) == nil)

        _ = try await cache.image(assetId: assetId, size: 44)

        #expect(cache.cachedImage(assetId: assetId, size: 44) != nil)
        #expect(cache.cachedImage(assetId: assetId, size: 11) == nil)
        let after = EntityIcon.image(genmoji, size: 22, assets: cache)
        #expect(png(after) != png(before))
        let colour = try #require(averageColour(after))
        #expect(colour.r > colour.g)
        #expect(colour.b > colour.g)
    }

    @Test func anUncachedGenmojiStartsItsOwnLoadAndAnnouncesIt() async throws {
        let assetId = "ia_" + String(repeating: "H", count: 43)
        let fetched = FetchLog()
        let cache = IconAssetCache(
            fetch: { requested in
                await fetched.record(requested)
                return Data([1, 2, 3])
            },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        let genmoji = IconEntity.agent(.genmoji(assetId: assetId, contentDescription: "Octopus"))
        let generation = EntityIcon.loadGeneration

        _ = EntityIcon.image(genmoji, size: 22, assets: cache)

        for _ in 0..<100 where EntityIcon.loadGeneration == generation {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fetched.ids() == [assetId])
        #expect(EntityIcon.loadGeneration > generation)
        #expect(cache.cachedImage(assetId: assetId, size: 44) != nil)
        #expect(png(EntityIcon.image(genmoji, size: 22, assets: cache))
            != png(EntityIcon.image(.agent(nil), size: 22)))
    }

    // MARK: - Helpers

    /// The drawn pixels, so two images compare by what they show.
    private func png(_ image: UIImage) -> Data {
        image.pngData() ?? Data()
    }

    private func averageColour(_ image: UIImage) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var pixels = [UInt8](repeating: 0, count: 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = image.cgImage else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (
            CGFloat(pixels[0]) / 255,
            CGFloat(pixels[1]) / 255,
            CGFloat(pixels[2]) / 255,
            CGFloat(pixels[3]) / 255
        )
    }

    private static func solid(_ colour: UIColor, side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private actor FetchLog {
        private var recorded: [String] = []

        func record(_ assetId: String) {
            recorded.append(assetId)
        }

        func ids() -> [String] { recorded }
    }
}
