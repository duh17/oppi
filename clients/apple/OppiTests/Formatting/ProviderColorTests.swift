import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("ProviderColor")
struct ProviderColorTests {
    private let palette = ThemePalettes.dark

    @Test func mapsKnownProvidersToPaletteColors() {
        expectColor("anthropic/claude-sonnet-4", equals: palette.orange)
        expectColor("openai/gpt-4.1", equals: palette.green)
        expectColor("google/gemini-2.5", equals: palette.blue)
        expectColor("meta/llama-3", equals: palette.cyan)
        expectColor("meta-llama/llama-3", equals: palette.cyan)
        expectColor("mistral/mistral-large", equals: palette.red)
        expectColor("mistralai/mistral-medium", equals: palette.red)
        expectColor("deepseek/deepseek-r1", equals: palette.blue)
        expectColor("xai/grok-3", equals: palette.yellow)

        // Provider matching is case-insensitive.
        expectColor("OPENAI/gpt-4o", equals: palette.green)
    }

    @Test func resolvesDeepSeekProviderDisplayMetadata() {
        #expect(ProviderIcon.displayName(for: "deepseek") == "DeepSeek")
        #expect(ProviderIcon.mark(for: "deepseek") == "D")
        #expect(ProviderIcon.logoAssetName(for: "deepseek") == "provider-deepseek")
    }

    @Test func fallsBackToPurpleForMissingMalformedOrUnknownModel() {
        expectColor(nil, equals: palette.purple)
        expectColor("", equals: palette.purple)
        expectColor("gpt-4o", equals: palette.purple)
        expectColor("custom/provider", equals: palette.purple)
    }

    private func expectColor(_ model: String?, equals expected: Color) {
        let resolved = ProviderColor.color(for: model, palette: palette)
        #expect(UIColor(resolved) == UIColor(expected))
    }
}
