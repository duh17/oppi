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

    @Test func siblingVersionsGetNoticeablyDifferentHue() {
        let a = hsba(UIColor(modelColor("openai/gpt-5.5")))
        let b = hsba(UIColor(modelColor("openai/gpt-5.4")))
        let c = hsba(UIColor(modelColor("openai/gpt-5.3-codex")))

        #expect(abs(a.hue - b.hue) >= 0.02)
        #expect(abs(b.hue - c.hue) >= 0.02)
    }

    @Test func providerLogoAssetNamesIncludeOmlx() {
        #expect(providerLogoAssetName("omlx") == "provider-omlx")
        #expect(ProviderIcon.logoAssetName(for: "omlx") == "provider-omlx")
        #expect(providerDisplayLabel("omlx") == "OMLX")
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
}
