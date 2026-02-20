import Testing
@testable import Oppi

@Suite("ModelSwitchPolicy")
struct ModelSwitchPolicyTests {
    @Test func fullModelIDAddsProviderPrefixWhenMissing() {
        let model = makeModel(provider: "anthropic", id: "claude-sonnet-4")
        #expect(ModelSwitchPolicy.fullModelID(for: model) == "anthropic/claude-sonnet-4")
    }

    @Test func fullModelIDKeepsPrefixedModelID() {
        let model = makeModel(provider: "anthropic", id: "anthropic/claude-sonnet-4")
        #expect(ModelSwitchPolicy.fullModelID(for: model) == "anthropic/claude-sonnet-4")
    }

    @Test func isCurrentSelectionMatchesCanonicalModelID() {
        let model = makeModel(provider: "anthropic", id: "claude-sonnet-4")
        #expect(
            ModelSwitchPolicy.isCurrentSelection(
                currentModel: "anthropic/claude-sonnet-4",
                selectedModel: model
            )
        )
    }

    @Test func isCurrentSelectionMatchesRawModelID() {
        let model = makeModel(provider: "anthropic", id: "claude-sonnet-4")
        #expect(
            ModelSwitchPolicy.isCurrentSelection(
                currentModel: "claude-sonnet-4",
                selectedModel: model
            )
        )
    }

    @Test func decisionRequiresConfirmationForMidSessionSwitch() {
        let selected = makeModel(provider: "openai", id: "gpt-4.1")

        let decision = ModelSwitchPolicy.decision(
            currentModel: "anthropic/claude-sonnet-4",
            selectedModel: selected,
            messageCount: 3
        )

        #expect(decision == .requireConfirmation)
    }

    @Test func decisionAppliesImmediatelyForEmptySession() {
        let selected = makeModel(provider: "openai", id: "gpt-4.1")

        let decision = ModelSwitchPolicy.decision(
            currentModel: "anthropic/claude-sonnet-4",
            selectedModel: selected,
            messageCount: 0
        )

        #expect(decision == .applyImmediately)
    }

    @Test func decisionIsUnchangedWhenSelectingCurrentModel() {
        let selected = makeModel(provider: "anthropic", id: "claude-sonnet-4")

        let decision = ModelSwitchPolicy.decision(
            currentModel: "anthropic/claude-sonnet-4",
            selectedModel: selected,
            messageCount: 42
        )

        #expect(decision == .unchanged)
    }

    private func makeModel(provider: String, id: String) -> ModelInfo {
        ModelInfo(
            id: id,
            name: id,
            provider: provider,
            contextWindow: 200_000
        )
    }
}
