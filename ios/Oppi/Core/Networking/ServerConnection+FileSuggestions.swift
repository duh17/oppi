import Foundation

extension ServerConnection {
    private static let fileSuggestionDebounce: Duration = .milliseconds(180)

    func fetchFileSuggestions(query: String) {
        chatState.fileSuggestionTask?.cancel()

        chatState.fileSuggestionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.fileSuggestionDebounce)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            do {
                let data = try await self.sendCommandAwaitingResult(
                    command: "get_file_suggestions",
                    timeout: .seconds(3)
                ) { requestId in
                    .getFileSuggestions(query: query, requestId: requestId)
                }

                guard !Task.isCancelled else {
                    return
                }

                self.chatState.fileSuggestions = FileSuggestionResult.from(data)?.items ?? []
            } catch {
                if !Task.isCancelled {
                    self.chatState.fileSuggestions = []
                }
            }
        }
    }

    func clearFileSuggestions() {
        chatState.fileSuggestionTask?.cancel()
        chatState.fileSuggestionTask = nil
        chatState.fileSuggestions = []
    }
}
