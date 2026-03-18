import Foundation

extension ServerConnection {

    /// Run local fuzzy search against the shared file index.
    /// For empty query, returns the first N files alphabetically.
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
            let sorted = candidates.sorted { $0.count < $1.count }
            chatState.fileSuggestions = sorted.prefix(limit).map { path in
                FileSuggestion(path: path, isDirectory: path.hasSuffix("/"))
            }
            return
        }

        chatState.fileSuggestionTask = Task { @MainActor [weak self] in
            let results = await Task.detached {
                FuzzyMatch.search(query: query, candidates: candidates, limit: limit)
            }.value

            guard let self, !Task.isCancelled else { return }

            self.chatState.fileSuggestions = results.map { scored in
                FileSuggestion(
                    path: scored.path,
                    isDirectory: scored.path.hasSuffix("/"),
                    matchPositions: scored.positions
                )
            }
            self.chatState.fileSuggestionTask = nil
        }
    }

    func clearFileSuggestions() {
        chatState.fileSuggestionTask?.cancel()
        chatState.fileSuggestionTask = nil
        chatState.fileSuggestions = []
    }
}
