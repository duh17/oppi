import Foundation
import Testing
@testable import Oppi

/// The on-device title path and the server title generator share one contract
/// (protocol/session-title.json); the server's tests read the same file.
@Suite("Session title contract")
@MainActor
struct SessionTitleContractTests {
    private struct Contract: Decodable {
        struct Prompt: Decodable {
            let name: String
            let firstMessage: String
            let prompt: String
        }

        struct Normalize: Decodable {
            let name: String
            let raw: String
            let expected: String?
        }

        let instructions: String
        let prompts: [Prompt]
        let normalize: [Normalize]
    }

    private static func contract() throws -> Contract {
        try JSONDecoder().decode(Contract.self, from: ProtocolFixtures.data("session-title.json"))
    }

    @Test func instructionsMatchServer() throws {
        #expect(ChatActionHandler.autoTitleInstructions == (try Self.contract().instructions))
    }

    @Test func promptsMatchServer() throws {
        for testCase in try Self.contract().prompts {
            #expect(
                ChatActionHandler.autoTitlePrompt(for: testCase.firstMessage) == testCase.prompt,
                "\(testCase.name)"
            )
        }
    }

    @Test func normalizationMatchesServer() throws {
        for testCase in try Self.contract().normalize {
            #expect(ChatActionHandler.normalizeTitle(testCase.raw) == testCase.expected, "\(testCase.name)")
        }
    }
}
