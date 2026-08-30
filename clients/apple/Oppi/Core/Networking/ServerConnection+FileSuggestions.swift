import Foundation

extension ServerConnection {

    /// Run local fuzzy search against the shared file index.
    /// For empty query, returns the first N files by shortest path.
    func fetchFileSuggestions(query: String) {
        chatState.fileSuggestionTask?.cancel()

        guard let index = fileIndexStore.paths, !index.isEmpty else {
            chatState.fileSuggestions = []
            return
        }

        let candidates = index
        let limit = ComposerAutocomplete.maxSuggestions

        if query.isEmpty {
            // Empty query: show first files sorted by path length (shortest = most relevant)
            chatState.fileSuggestions = FileSuggestion.ranked(query: query, paths: candidates, limit: limit)
            return
        }

        chatState.fileSuggestionTask = Task { @MainActor [weak self] in
            let ranked = await Task.detached {
                FileSuggestion.ranked(query: query, paths: candidates, limit: limit)
            }.value

            guard let self, !Task.isCancelled else { return }

            self.chatState.fileSuggestions = ranked
            self.chatState.fileSuggestionTask = nil
        }
    }

    func clearFileSuggestions() {
        chatState.fileSuggestionTask?.cancel()
        chatState.fileSuggestionTask = nil
        chatState.fileSuggestions = []
    }

}
