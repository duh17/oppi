import Foundation

extension ServerConnection {

    /// Run local fuzzy search against the shared file index.
    /// For empty query, returns the first N files by shortest path.
    ///
    /// Non-empty ranking runs off the main thread. A newer keystroke bumps
    /// `fileSuggestionGeneration` so a stale result is discarded even if the
    /// cancelled task still finishes.
    func fetchFileSuggestions(query: String) {
        chatState.fileSuggestionTask?.cancel()
        chatState.fileSuggestionGeneration &+= 1
        let generation = chatState.fileSuggestionGeneration

        guard let ranker = fileIndexStore.suggestionRanker, !ranker.index.isEmpty else {
            chatState.fileSuggestions = []
            return
        }

        let limit = ComposerAutocomplete.maxSuggestions

        if query.isEmpty {
            // Cached empty-query top-N: O(limit) prefix, safe on main.
            chatState.fileSuggestions = ranker.ranked(query: query, limit: limit)
            chatState.fileSuggestionTask = nil
            return
        }

        chatState.fileSuggestionTask = Task { @MainActor [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                ranker.ranked(query: query, limit: limit)
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.chatState.fileSuggestionGeneration == generation
            else { return }

            self.chatState.fileSuggestions = ranked
            self.chatState.fileSuggestionTask = nil
        }
    }

    func clearFileSuggestions() {
        chatState.fileSuggestionTask?.cancel()
        chatState.fileSuggestionTask = nil
        chatState.fileSuggestionGeneration &+= 1
        chatState.fileSuggestions = []
    }

}
