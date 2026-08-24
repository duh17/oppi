import Testing
@testable import Oppi

@Suite("Mac model selection")
struct MacModelSelectionTests {

    @Test func fullModelIDAddsProviderWhenMissing() {
        let model = ModelInfo(id: "gpt-5.5", name: "GPT 5.5", provider: "openai", contextWindow: 200_000)

        #expect(MacModelSelection.fullModelID(for: model) == "openai/gpt-5.5")
    }

    @Test func fullModelIDDoesNotDoublePrefix() {
        let model = ModelInfo(id: "openrouter/z-ai/glm-5", name: "GLM 5", provider: "openrouter", contextWindow: 256_000)

        #expect(MacModelSelection.fullModelID(for: model) == "openrouter/z-ai/glm-5")
    }

    @Test func commandModelIDStripsOnlyMatchingProviderPrefix() {
        let prefixed = ModelInfo(id: "openai/gpt-5.5", name: "GPT 5.5", provider: "openai", contextWindow: 200_000)
        let nested = ModelInfo(id: "z-ai/glm-5", name: "GLM 5", provider: "openrouter", contextWindow: 256_000)

        #expect(MacModelSelection.commandModelID(for: prefixed) == "gpt-5.5")
        #expect(MacModelSelection.commandModelID(for: nested) == "z-ai/glm-5")
    }

    @Test func currentModelMatchesBareOrFullID() {
        let model = ModelInfo(id: "gpt-5.5", name: "GPT 5.5", provider: "openai", contextWindow: 200_000)

        #expect(MacModelSelection.isCurrent(model: model, currentModel: "gpt-5.5"))
        #expect(MacModelSelection.isCurrent(model: model, currentModel: "openai/gpt-5.5"))
        #expect(!MacModelSelection.isCurrent(model: model, currentModel: "anthropic/claude-sonnet"))
    }

    @Test func markingDefaultStarsOnlyThePersistedGlobalDefault() {
        let sonnet = ModelInfo(
            id: "anthropic/claude-sonnet-4",
            name: "Sonnet",
            provider: "anthropic",
            contextWindow: 200_000,
            isDefault: true
        )
        let gpt = ModelInfo(
            id: "gpt-5.5",
            name: "GPT 5.5",
            provider: "openai",
            contextWindow: 200_000
        )

        let updated = MacModelSelection.markingDefault([sonnet, gpt], as: gpt)

        #expect(updated.map(\.isDefault) == [false, true])
        #expect(updated[1].id == "gpt-5.5")
    }
}
