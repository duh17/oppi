import Testing
@testable import Oppi

@Suite("SessionModelSummaryBuilder")
struct SessionModelSummaryBuilderTests {

    @Test func usesPrimaryModelFirst() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "anthropic/claude-sonnet-4-6",
            descendantModels: ["openai-codex/gpt-5.3-codex"]
        )

        #expect(result.map(\.rawModel) == [
            "anthropic/claude-sonnet-4-6",
            "openai-codex/gpt-5.3-codex",
        ])
        #expect(result.first?.provider == "anthropic")
        #expect(result.first?.label == "claude-sonnet-4-6")
    }

    @Test func deduplicatesRepeatedModels() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "openai-codex/gpt-5.3-codex",
            descendantModels: [
                "openai-codex/gpt-5.3-codex",
                "anthropic/claude-sonnet-4-6",
                "anthropic/claude-sonnet-4-6",
            ]
        )

        #expect(result.map(\.rawModel) == [
            "openai-codex/gpt-5.3-codex",
            "anthropic/claude-sonnet-4-6",
        ])
    }

    @Test func keepsNestedOpenRouterModelPathInLabel() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "openrouter/z.ai/glm-5"
        )

        #expect(result.count == 1)
        #expect(result[0].provider == "openrouter")
        #expect(result[0].label == "z.ai/glm-5")
    }

    @Test func dropsNilAndBlankModels() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "  ",
            descendantModels: ["", "   ", "mistral/magistral-medium"]
        )

        #expect(result.map(\.rawModel) == ["mistral/magistral-medium"])
        #expect(result[0].label == "magistral-medium")
    }

    @Test func fallsBackToRawModelWithoutProviderPrefix() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "claude-sonnet-4-6"
        )

        #expect(result.count == 1)
        #expect(result[0].provider.isEmpty)
        #expect(result[0].label == "claude-sonnet-4-6")
    }
}
