import Foundation
import Testing
@testable import Oppi

@Suite("ThinkingLevelMenuSource")
struct ThinkingLevelMenuSourceTests {
    @Test func missingCatalogFallsBackToAllCases() {
        #expect(ThinkingLevelMenuSource.levels(for: nil) == ThinkingLevel.allCases)
        #expect(
            ThinkingLevelMenuSource.levels(
                for: ModelInfo(id: "sonnet", name: "Sonnet", provider: "anthropic", contextWindow: 200_000)
            ) == ThinkingLevel.allCases
        )
    }

    @Test func advertisedLevelsKeepProtocolOrderAndDropUnsupported() {
        let model = ModelInfo(
            id: "sonnet",
            name: "Sonnet",
            provider: "anthropic",
            contextWindow: 200_000,
            thinkingLevels: [.high, .off, .low]
        )
        #expect(ThinkingLevelMenuSource.levels(for: model) == [.off, .low, .high])
    }

    @Test func looksUpCurrentSessionModelFromCatalog() {
        let models = [
            ModelInfo(
                id: "claude-sonnet-4-0",
                name: "Sonnet",
                provider: "anthropic",
                contextWindow: 200_000,
                thinkingLevels: [.off, .high]
            ),
            ModelInfo(
                id: "gpt-5.5",
                name: "GPT",
                provider: "openai",
                contextWindow: 200_000,
                thinkingLevels: [.off]
            ),
        ]
        #expect(
            ThinkingLevelMenuSource.levels(for: "anthropic/claude-sonnet-4-0", in: models) == [.off, .high]
        )
        #expect(ThinkingLevelMenuSource.levels(for: "openai/gpt-5.5", in: models) == [.off])
    }
}
