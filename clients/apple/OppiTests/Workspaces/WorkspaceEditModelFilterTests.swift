import Testing
@testable import Oppi

@Suite("WorkspaceEditModelFilter")
struct WorkspaceEditModelFilterTests {

    private func model(id: String, name: String, provider: String = "test") -> ModelInfo {
        ModelInfo(id: id, name: name, provider: provider, contextWindow: 128_000)
    }

    private var sampleModels: [ModelInfo] {
        [
            model(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4"),
            model(id: "claude-opus-4-20250514", name: "Claude Opus 4"),
            model(id: "gpt-4o", name: "GPT-4o"),
        ]
    }

    @Test func emptyQueryReturnsAll() {
        let result = WorkspaceEditView.filterModels(sampleModels, query: "")
        #expect(result == sampleModels)
    }

    @Test func exactIdMatchReturnsAll() {
        let result = WorkspaceEditView.filterModels(sampleModels, query: "gpt-4o")
        #expect(result == sampleModels)
    }

    @Test func fuzzyMatchFiltersAndRanks() {
        let result = WorkspaceEditView.filterModels(sampleModels, query: "son")
        #expect(!result.isEmpty)
        #expect(result[0].id == "claude-sonnet-4-20250514")
        // gpt-4o should not match "son"
        #expect(!result.contains(where: { $0.id == "gpt-4o" }))
    }

    @Test func fuzzyMatchAcrossNameAndId() {
        let models = [
            model(id: "x-model-1", name: "Alpha"),
            model(id: "y-model-2", name: "Opus Special"),
        ]
        // "opus" matches second model's name but not ID prefix
        let result = WorkspaceEditView.filterModels(models, query: "opus")
        #expect(result.count == 1)
        #expect(result[0].id == "y-model-2")

        // "x-model" matches first model's ID
        let result2 = WorkspaceEditView.filterModels(models, query: "x-model")
        #expect(result2.count == 1)
        #expect(result2[0].id == "x-model-1")
    }

    @Test func noMatchReturnsEmpty() {
        let result = WorkspaceEditView.filterModels(sampleModels, query: "xyz123qqq")
        #expect(result.isEmpty)
    }
}

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
