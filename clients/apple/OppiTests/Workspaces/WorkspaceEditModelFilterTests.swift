import Testing
@testable import Oppi

@Suite("AutoTitleSettingsView model filtering")
struct AutoTitleSettingsViewModelFilteringTests {

    private func model(id: String, name: String, provider: String) -> ModelInfo {
        ModelInfo(id: id, name: name, provider: provider, contextWindow: 128_000)
    }

    @Test func filtersIncompatibleProvidersAndSortsProviders() {
        let models = [
            model(id: "gpt-5.3-codex", name: "Codex", provider: "openai-codex"),
            model(id: "claude-sonnet-4-6", name: "Sonnet", provider: "anthropic"),
            model(id: "gemini-2.5-pro", name: "Gemini Pro", provider: "google")
        ]

        let groups = AutoTitleModelCatalog.compatibleModelGroups(from: models)
        #expect(groups.map(\.provider) == ["anthropic", "google"])
        #expect(groups.flatMap(\.models).map(\.name) == ["Sonnet", "Gemini Pro"])
    }

    @Test func firstCompatibleModelIDNormalizesProviderPrefix() {
        let models = [
            model(id: "gpt-5.3-codex", name: "Codex", provider: "openai-codex"),
            model(id: "claude-sonnet-4-6", name: "Sonnet", provider: "anthropic")
        ]

        let first = AutoTitleModelCatalog.firstCompatibleModelID(from: models)
        #expect(first == "anthropic/claude-sonnet-4-6")
    }

    @Test func fullModelIDKeepsExistingPrefix() {
        let prefixed = model(
            id: "anthropic/claude-opus-4-6",
            name: "Opus",
            provider: "anthropic"
        )

        #expect(AutoTitleModelCatalog.fullModelID(for: prefixed) == "anthropic/claude-opus-4-6")
    }
}
