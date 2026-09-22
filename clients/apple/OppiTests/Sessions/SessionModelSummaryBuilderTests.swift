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

    @Test func usesLastPathComponentForNestedModelIDs() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
        )

        #expect(result.count == 1)
        #expect(result[0].provider == "mlx-serve")
        #expect(result[0].label == "Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit")
        #expect(!result[0].label.contains("ddalcu/"))
    }

    @Test func usesLastPathComponentForOpenRouterNestedIDs() {
        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "openrouter/z.ai/glm-5"
        )

        #expect(result.count == 1)
        #expect(result[0].provider == "openrouter")
        #expect(result[0].label == "glm-5")
    }

    @Test func prefersCatalogDisplayNameForAnyModel() {
        let catalog = [
            ModelInfo(
                id: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
                name: "Qwen 3.8 Flash Next",
                provider: "mlx-serve",
                contextWindow: 200_000
            ),
            ModelInfo(
                id: "xai/grok-4.6",
                name: "Grok 4.6",
                provider: "xai",
                contextWindow: 256_000
            ),
        ]

        let mlx = SessionModelSummaryBuilder.summaries(
            primaryModel: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
            catalogModels: catalog
        )
        let grok = SessionModelSummaryBuilder.summaries(
            primaryModel: "xai/grok-4.6",
            catalogModels: catalog
        )

        #expect(mlx.first?.label == "Qwen 3.8 Flash Next")
        #expect(grok.first?.label == "Grok 4.6")
    }

    @Test func ignoresCatalogNamesThatAreStillRawIDs() {
        let catalog = [
            ModelInfo(
                id: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
                name: "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
                provider: "mlx-serve",
                contextWindow: 200_000
            ),
        ]

        let result = SessionModelSummaryBuilder.summaries(
            primaryModel: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
            catalogModels: catalog
        )

        #expect(result.first?.label == "Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit")
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
