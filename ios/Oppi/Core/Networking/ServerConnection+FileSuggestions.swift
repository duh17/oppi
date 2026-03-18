import Foundation

extension ServerConnection {

    /// Load the workspace file index for local fuzzy search.
    /// Called once per session; cached in chatState.
    func loadFileIndex(workspaceId: String) {
        guard chatState.fileIndex == nil, chatState.fileIndexTask == nil else { return }

        chatState.fileIndexTask = Task { @MainActor [weak self] in
            guard let self, let api = self.apiClient else { return }
            do {
                let response = try await api.fetchFileIndex(workspaceId: workspaceId)
                self.chatState.fileIndex = response.paths
            } catch {
                // Silently fall back to empty index
                self.chatState.fileIndex = []
            }
            self.chatState.fileIndexTask = nil
        }
    }

    /// Run local fuzzy search against the cached file index.
    func fetchFileSuggestions(query: String) {
        chatState.fileSuggestionTask?.cancel()

        guard let index = chatState.fileIndex, !index.isEmpty else {
            chatState.fileSuggestions = []
            return
        }

        let candidates = index
        let limit = ComposerAutocomplete.maxSuggestions

        chatState.fileSuggestionTask = Task { @MainActor [weak self] in
            // Run fuzzy match off the main actor
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
