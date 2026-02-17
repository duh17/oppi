import Foundation

// MARK: - Model, Thinking, and Slash Commands

extension ServerConnection {
    // ── Model ──

    func setModel(provider: String, modelId: String) async throws {
        try await send(.setModel(provider: provider, modelId: modelId))
    }

    func cycleModel() async throws {
        try await send(.cycleModel())
    }

    // ── Thinking ──

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        try await send(.setThinkingLevel(level: level))
    }

    func cycleThinkingLevel() async throws {
        try await send(.cycleThinkingLevel())
    }

    /// Sync thinking level from a session state update (connected/state messages).
    func syncThinkingLevel(from session: Session) {
        guard let levelStr = session.thinkingLevel,
              let level = ThinkingLevel(rawValue: levelStr),
              thinkingLevel != level else { return }
        thinkingLevel = level
    }

    // ── Slash Commands ──

    func scheduleSlashCommandsRefresh(for session: Session, force: Bool) {
        slashCommandsTask?.cancel()
        slashCommandsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSlashCommands(for: session, force: force)
        }
    }

    func handleSlashCommandsResult(
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) {
        if let expectedRequestId = slashCommandsRequestId,
           let requestId,
           requestId != expectedRequestId {
            return
        }

        defer { slashCommandsRequestId = nil }

        guard success else {
            return
        }

        slashCommands = Self.parseSlashCommands(from: data)

        if let session = sessionStore.sessions.first(where: { $0.id == sessionId }) {
            slashCommandsCacheKey = slashCommandCacheKey(for: session)
        } else {
            slashCommandsCacheKey = nil
        }
    }

    // ── Session Commands ──

    func newSession() async throws {
        try await send(.newSession())
    }

    func setSessionName(_ name: String) async throws {
        try await send(.setSessionName(name: name))
    }

    func compact(instructions: String? = nil) async throws {
        try await send(.compact(customInstructions: instructions))
    }

    func runBash(_ command: String) async throws {
        try await send(.bash(command: command))
    }

    // MARK: - Internal Helpers

    func slashCommandCacheKey(for session: Session) -> String {
        "\(session.id)|\(session.workspaceId ?? "")"
    }

    func refreshSlashCommands(for session: Session, force: Bool) async {
        let cacheKey = slashCommandCacheKey(for: session)
        if !force,
           slashCommandsCacheKey == cacheKey,
           !slashCommands.isEmpty {
            return
        }

        let requestId = UUID().uuidString
        slashCommandsRequestId = requestId

        do {
            try await send(.getCommands(requestId: requestId))
        } catch {
            slashCommandsRequestId = nil
        }
    }

    static func parseSlashCommands(from data: JSONValue?) -> [SlashCommand] {
        guard let commandValues = data?.objectValue?["commands"]?.arrayValue else {
            return []
        }

        var deduped: [String: SlashCommand] = [:]
        for value in commandValues {
            guard let command = SlashCommand(value) else { continue }
            let key = command.name.lowercased()
            if deduped[key] == nil {
                deduped[key] = command
            }
        }

        return deduped.values.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            if lhsName == rhsName {
                return lhs.source.sortRank < rhs.source.sortRank
            }
            return lhsName < rhsName
        }
    }
}
