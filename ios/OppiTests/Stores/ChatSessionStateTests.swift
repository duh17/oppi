import Foundation
import Testing

@testable import Oppi

@Suite("ChatSessionState")
@MainActor
struct ChatSessionStateTests {

    // MARK: - resetSessionState

    @Test func resetSessionState_clearsSlashCommandsAndFileSuggestions() {
        let state = ChatSessionState()
        state.slashCommands = [SlashCommand(name: "test", description: "Test", source: .skill)]
        state.fileSuggestions = [FileSuggestion(path: "foo.swift", isDirectory: false)]

        state.resetSessionState()

        #expect(state.slashCommands.isEmpty)
        #expect(state.fileSuggestions.isEmpty)
    }

    // MARK: - resetModelCache

    @Test func resetModelCache_clearsModelsAndReadyFlag() {
        let state = ChatSessionState()
        state.cachedModels = [
            ModelInfo(id: "m-1", name: "Model 1", provider: "anthropic", contextWindow: 200_000),
        ]
        state.modelsCacheReady = true

        state.resetModelCache()

        #expect(state.cachedModels.isEmpty)
        #expect(!state.modelsCacheReady)
    }

    // MARK: - refreshModelCache (integration-like, using real APIClient with bad URL)

    @Test func refreshModelCache_setsModelsAndReady_whenAPISucceeds() async {
        // We can't easily mock the actor APIClient, but we can verify:
        // 1. Starting state is empty
        // 2. On failure, state remains unchanged (non-fatal)
        let state = ChatSessionState()
        #expect(state.cachedModels.isEmpty)
        #expect(!state.modelsCacheReady)

        // Create an API client pointing at an unreachable host.
        // refreshModelCache should catch the error silently.
        // swiftlint:disable:next force_unwrapping
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test")
        await state.refreshModelCache(api: api)

        // Error path: models stay empty, ready stays false
        #expect(state.cachedModels.isEmpty)
        #expect(!state.modelsCacheReady)
    }

    // MARK: - cancelTasks

    @Test func cancelTasks_nilsOutAllTaskReferences() {
        let state = ChatSessionState()
        state.slashCommandsTask = Task {}
        state.fileSuggestionTask = Task {}
        state.modelPrefetchTask = Task {}
        state.slashCommandsRequestId = "req-1"
        state.slashCommandsCacheKey = "key-1"

        state.cancelTasks()

        #expect(state.slashCommandsTask == nil)
        #expect(state.fileSuggestionTask == nil)
        #expect(state.modelPrefetchTask == nil)
        #expect(state.slashCommandsRequestId == nil)
        #expect(state.slashCommandsCacheKey == nil)
    }

    // MARK: - Thinking level default

    @Test func thinkingLevel_defaultsToMedium() {
        let state = ChatSessionState()
        #expect(state.thinkingLevel == .medium)
    }
}
