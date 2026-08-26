import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("ModelColorHelpers")
struct ModelColorHelpersTests {
    @Test func separatesProviderFromStableModelID() {
        let identity = modelDisplayIdentity("anthropic/claude-sonnet-4-6-20250514")

        #expect(identity.provider == "anthropic")
        #expect(identity.providerDisplayName == "Anthropic")
        #expect(identity.displayName == "sonnet-4-6")
        #expect(identity.normalizedModelID == "sonnet-4-6")
        #expect(identity.aggregationKey == "anthropic/sonnet-4-6")
    }

    @Test func modelColorIgnoresProviderAndTimestamp() {
        let direct = UIColor(modelColor("openai/gpt-5.5"))
        let aliasedProvider = UIColor(modelColor("openai-codex/gpt-5.5"))
        let timestamped = UIColor(modelColor("openrouter/gpt-5.5-20250514"))

        #expect(direct == aliasedProvider)
        #expect(direct == timestamped)
    }

    @Test func newerStableVersionsGetBrighterWithinFamily() {
        let newer = hsba(UIColor(modelColor("openai/gpt-5.5")))
        let older = hsba(UIColor(modelColor("openai/gpt-5.4")))

        #expect(newer.brightness > older.brightness)
        #expect(newer.saturation >= older.saturation)
    }

    @Test func claudeModelsStayInAnthropicOrangeBand() {
        let color = hsba(UIColor(modelColor("anthropic/claude-sonnet-4-6")))

        #expect(color.hue >= 0.03)
        #expect(color.hue <= 0.09)
    }

    @Test func siblingVersionsGetNoticeablyDifferentHue() {
        let a = hsba(UIColor(modelColor("openai/gpt-5.5")))
        let b = hsba(UIColor(modelColor("openai/gpt-5.4")))
        let c = hsba(UIColor(modelColor("openai/gpt-5.3-codex")))

        #expect(abs(a.hue - b.hue) >= 0.02)
        #expect(abs(b.hue - c.hue) >= 0.02)
    }

    @Test func grokModelsUseThemeAdaptiveMonochrome() {
        let dark = resolvedHSBA(modelColor("xai/grok-4.6"), style: .dark)
        let light = resolvedHSBA(modelColor("xai/grok-4.6"), style: .light)

        #expect(dark.saturation < 0.08)
        #expect(light.saturation < 0.08)
        #expect(dark.brightness >= 0.88)
        #expect(light.brightness <= 0.22)
        #expect(dark.brightness > light.brightness + 0.5)
    }

    @Test func grokModelColorIgnoresProviderAndTimestamp() {
        let direct = resolvedUIColor(modelColor("xai/grok-4.6"), style: .dark)
        let openRouter = resolvedUIColor(modelColor("openrouter/x-ai/grok-4.6"), style: .dark)
        let timestamped = resolvedUIColor(modelColor("xai/grok-4.6-20260301"), style: .dark)

        #expect(direct == openRouter)
        #expect(direct == timestamped)
    }

    @Test func grokFamiliesAndVersionsUseDifferentGraySteps() {
        let flagshipDark = resolvedHSBA(modelColor("xai/grok-4.6"), style: .dark)
        let olderDark = resolvedHSBA(modelColor("xai/grok-4.5"), style: .dark)
        let codeDark = resolvedHSBA(modelColor("xai/grok-code-fast-1"), style: .dark)
        let flagshipLight = resolvedHSBA(modelColor("xai/grok-4.6"), style: .light)
        let olderLight = resolvedHSBA(modelColor("xai/grok-4.5"), style: .light)

        #expect(flagshipDark.brightness > olderDark.brightness)
        #expect(abs(flagshipDark.brightness - codeDark.brightness) >= 0.06)
        #expect(flagshipLight.brightness < olderLight.brightness)
    }

    @Test func providerLogoAssetNamesIncludeOmlx() {
        #expect(providerLogoAssetName("omlx") == "provider-omlx")
        #expect(ProviderIcon.logoAssetName(for: "omlx") == "provider-omlx")
        #expect(providerDisplayLabel("omlx") == "OMLX")
    }

    @Test func providerLogoAssetNamesIncludeQwen() {
        #expect(providerLogoAssetName("qwen") == "provider-qwen")
        #expect(providerLogoAssetName("qwen-token-plan") == "provider-qwen")
        #expect(providerLogoAssetName("qwen-token-plan-cn") == "provider-qwen")
        #expect(ProviderIcon.logoAssetName(for: "qwen-token-plan") == "provider-qwen")
        #expect(providerDisplayLabel("qwen") == "Qwen")
        #expect(providerDisplayLabel("qwen-token-plan") == "Qwen Token Plan")
        #expect(providerDisplayLabel("qwen-token-plan-cn") == "Qwen Token Plan CN")
    }

    @Test func providerLogoAssetNamesIncludeCursorAndOpenCode() {
        #expect(providerLogoAssetName("cursor") == "provider-cursor")
        #expect(ProviderIcon.logoAssetName(for: "cursor") == "provider-cursor")
        #expect(providerDisplayLabel("cursor") == "Cursor")

        #expect(providerLogoAssetName("opencode") == "provider-opencode")
        #expect(providerLogoAssetName("opencode-go") == "provider-opencode")
        #expect(ProviderIcon.logoAssetName(for: "opencode-go") == "provider-opencode")
        #expect(providerDisplayLabel("opencode") == "OpenCode")
        #expect(providerDisplayLabel("opencode-go") == "OpenCode Go")
    }

    /// Template rendering keeps only alpha, so an asset that converted to an
    /// opaque rectangle would show as a filled block instead of a mark.
    @Test(arguments: ["provider-cursor", "provider-opencode"])
    func newProviderTemplateAssetsCarryTransparency(assetName: String) throws {
        let image = try #require(UIImage(named: assetName))
        let raster = try #require(rasterize(image))

        #expect(raster.opaqueFraction > 0.1)
        #expect(raster.opaqueFraction < 0.9)
    }

    /// OpenCode's mark is a frame; the vendor file fills that opening with an
    /// opaque backdrop that has to be dropped during asset generation.
    @Test func openCodeTemplateAssetKeepsFrameOpening() throws {
        let image = try #require(UIImage(named: "provider-opencode"))
        let raster = try #require(rasterize(image))

        #expect(raster.alpha(normalizedX: 0.5, normalizedY: 0.5) == 0)
    }

    @Test func qwenTemplateAssetPreservesNegativeSpace() throws {
        let image = try #require(UIImage(named: "provider-qwen"))
        let raster = try #require(rasterize(image))

        #expect(raster.alpha(normalizedX: 0.5, normalizedY: 0.5) == 255)
        #expect(raster.alpha(normalizedX: 0.5, normalizedY: 0.375) == 0)
    }

    @Test func providerIconTintMeetsContrastFloorOnThemeSurfaces() {
        let palette = ThemePalettes.dark
        let backgrounds = [palette.bg, palette.bgDark, palette.bgHighlight]
        let preferred = [palette.green, palette.blue, palette.orange, palette.red, palette.purple]

        for color in preferred {
            let tinted = providerIconTint(color, palette: palette)
            let ratio = minimumContrastRatio(of: tinted, on: backgrounds)
            #expect(ratio != nil)
            #expect((ratio ?? 0) >= 3.0)
        }
    }

    private struct RasterAlpha {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func alpha(normalizedX: CGFloat, normalizedY: CGFloat) -> UInt8 {
            let x = min(width - 1, max(0, Int(CGFloat(width) * normalizedX)))
            let y = min(height - 1, max(0, Int(CGFloat(height) * normalizedY)))
            return pixels[((y * width) + x) * 4 + 3]
        }

        var opaqueFraction: Double {
            let total = width * height
            guard total > 0 else { return 0 }
            var opaque = 0
            for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 127 {
                opaque += 1
            }
            return Double(opaque) / Double(total)
        }
    }

    private func rasterize(_ image: UIImage) -> RasterAlpha? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RasterAlpha(width: width, height: height, pixels: pixels)
    }

    private struct HSBA {
        let hue: CGFloat
        let saturation: CGFloat
        let brightness: CGFloat
        let alpha: CGFloat
    }

    private func hsba(_ color: UIColor) -> HSBA {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        let resolved = color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #expect(resolved)
        return HSBA(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    private func resolvedUIColor(_ color: Color, style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func resolvedHSBA(_ color: Color, style: UIUserInterfaceStyle) -> HSBA {
        hsba(resolvedUIColor(color, style: style))
    }
}
