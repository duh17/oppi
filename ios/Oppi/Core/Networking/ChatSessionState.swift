import Foundation

/// Observable state bag for per-connection chat UI concerns.
///
/// Extracted from `ServerConnection` to isolate view-model properties
/// (composer draft, model/slash command caches, file suggestions, thinking level)
/// from transport and networking state. Views that only need these properties
/// observe `ChatSessionState` instead of the full `ServerConnection`.
///
/// Owned by `ServerConnection` as a `let` property. Server message handlers
/// write to it; views read from it via `@Environment(ChatSessionState.self)`.
@MainActor @Observable
final class ChatSessionState {

    // MARK: - Composer

    var composerDraft: String?

    // MARK: - Scroll restoration (non-observed, persisted via RestorationState)

    @ObservationIgnored var scrollAnchorItemId: String?
    @ObservationIgnored var scrollWasNearBottom: Bool = true

    // MARK: - Thinking level

    var thinkingLevel: ThinkingLevel = .medium

    // MARK: - Slash commands

    var slashCommands: [SlashCommand] = []
    var slashCommandsCacheKey: String?
    var slashCommandsRequestId: String?
    var slashCommandsTask: Task<Void, Never>?

    // MARK: - Model cache

    var cachedModels: [ModelInfo] = []
    var modelsCacheReady = false
    var modelPrefetchTask: Task<Void, Never>?

    // MARK: - File suggestions

    var fileSuggestions: [FileSuggestion] = []
    var fileSuggestionTask: Task<Void, Never>?



    // MARK: - Lifecycle

    /// Cancel all in-flight background tasks.
    func cancelTasks() {
        slashCommandsTask?.cancel()
        slashCommandsTask = nil
        slashCommandsRequestId = nil
        slashCommandsCacheKey = nil
        fileSuggestionTask?.cancel()
        fileSuggestionTask = nil
        modelPrefetchTask?.cancel()
        modelPrefetchTask = nil
    }

    /// Reset all cached state (called on session disconnect).
    func resetSessionState() {
        cancelTasks()
        slashCommands = []
        fileSuggestions = []
    }

    /// Reset model cache (called on server disconnect/invalidation).
    func resetModelCache() {
        modelsCacheReady = false
        cachedModels = []
        modelPrefetchTask?.cancel()
        modelPrefetchTask = nil
    }
}
