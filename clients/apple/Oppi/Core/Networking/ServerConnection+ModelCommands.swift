import Foundation

// MARK: - Model, Thinking, and Slash Commands

extension ServerConnection {
    // ── Model ──

    func setModel(provider: String, modelId: String) async throws {
        try await send(.setModel(provider: provider, modelId: modelId))
    }

    // periphery:ignore - API surface for model cycling
    func cycleModel() async throws {
        try await send(.cycleModel())
    }

    // ── Thinking ──

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        try await send(.setThinkingLevel(level: level))
    }

    // periphery:ignore - used by ChatActionHandler; false positive from extension file split
    func cycleThinkingLevel() async throws {
        try await send(.cycleThinkingLevel())
    }

    /// Sync thinking level from a session state update (connected/state messages).
    func syncThinkingLevel(from session: Session) {
        guard let levelStr = session.thinkingLevel,
              let level = ThinkingLevel(rawValue: levelStr),
              chatState.thinkingLevel != level else { return }
        chatState.thinkingLevel = level
    }

    // ── Slash Commands ──

    func scheduleSlashCommandsRefresh(for session: Session, force: Bool) {
        chatState.slashCommandsTask?.cancel()
        chatState.slashCommandsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSlashCommands(for: session, force: force)
        }
    }

    func handleSlashCommandsResult(
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error _: String?,
        sessionId: String
    ) {
        if let expectedRequestId = chatState.slashCommandsRequestId,
           let requestId,
           requestId != expectedRequestId {
            return
        }

        defer { chatState.slashCommandsRequestId = nil }

        guard success else {
            return
        }

        chatState.slashCommands = Self.parseSlashCommands(from: data)

        if let session = sessionStore.sessions.first(where: { $0.id == sessionId }) {
            chatState.slashCommandsCacheKey = slashCommandCacheKey(for: session)
        } else {
            chatState.slashCommandsCacheKey = nil
        }
    }

    // ── Session Commands ──

    // periphery:ignore - used by ChatActionHandler; false positive from extension file split
    func newSession() async throws {
        try await send(.newSession())
    }

    func setSessionName(_ name: String) async throws {
        try await send(.setSessionName(name: name))
    }

    func compact(instructions: String? = nil) async throws {
        try await send(.compact(customInstructions: instructions))
    }

    func getSessionStats() async throws -> SessionStatsSnapshot? {
        let data = try await sendCommandAwaitingResult(command: "get_session_stats") { requestId in
            .getSessionStats(requestId: requestId)
        }
        return Self.parseSessionStats(from: data)
    }

    // MARK: - Internal Helpers

    func slashCommandCacheKey(for session: Session) -> String {
        "\(session.id)|\(session.workspaceId ?? "")"
    }

    func refreshSlashCommands(for session: Session, force: Bool) async {
        let cacheKey = slashCommandCacheKey(for: session)
        if !force,
           chatState.slashCommandsCacheKey == cacheKey,
           !chatState.slashCommands.isEmpty {
            return
        }

        let requestId = UUID().uuidString
        chatState.slashCommandsRequestId = requestId

        do {
            try await send(.getCommands(requestId: requestId))
        } catch {
            chatState.slashCommandsRequestId = nil
        }
    }

    static func parseSessionStats(from data: JSONValue?) -> SessionStatsSnapshot? {
        guard let root = data?.objectValue,
              let tokenObject = root["tokens"]?.objectValue else {
            return nil
        }

        let input = parseInt(tokenObject["input"]) ?? 0
        let output = parseInt(tokenObject["output"]) ?? 0
        let cacheRead = parseInt(tokenObject["cacheRead"]) ?? 0
        let cacheWrite = parseInt(tokenObject["cacheWrite"]) ?? 0
        let total = parseInt(tokenObject["total"]) ?? (input + output + cacheRead + cacheWrite)
        let cost = parseDouble(root["cost"]) ?? 0

        return SessionStatsSnapshot(
            tokens: SessionTokenStats(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                total: total
            ),
            cost: cost,
            contextComposition: parseContextComposition(root["contextComposition"])
        )
    }

    private static func parseContextComposition(_ value: JSONValue?) -> SessionContextCompositionSnapshot? {
        guard let object = value?.objectValue else {
            return nil
        }

        let piSystemPromptChars = parseInt(object["piSystemPromptChars"]) ?? 0
        let piSystemPromptTokens = parseInt(object["piSystemPromptTokens"]) ?? 0
        let agentsChars = parseInt(object["agentsChars"]) ?? 0
        let agentsTokens = parseInt(object["agentsTokens"]) ?? 0

        let agentsFiles: [ContextFileTokenSnapshot] = object["agentsFiles"]?.arrayValue?.compactMap { item in
            guard let file = item.objectValue,
                  let path = file["path"]?.stringValue else {
                return nil
            }

            return ContextFileTokenSnapshot(
                path: path,
                chars: parseInt(file["chars"]) ?? 0,
                tokens: parseInt(file["tokens"]) ?? 0
            )
        } ?? []

        let skillsListingChars = parseInt(object["skillsListingChars"]) ?? 0
        let skillsListingTokens = parseInt(object["skillsListingTokens"]) ?? 0

        return SessionContextCompositionSnapshot(
            piSystemPromptChars: piSystemPromptChars,
            piSystemPromptTokens: piSystemPromptTokens,
            agentsChars: agentsChars,
            agentsTokens: agentsTokens,
            agentsFiles: agentsFiles,
            skillsListingChars: skillsListingChars,
            skillsListingTokens: skillsListingTokens
        )
    }

    private static func parseInt(_ value: JSONValue?) -> Int? {
        if let number = value?.numberValue {
            return Int(number)
        }
        if let string = value?.stringValue {
            return Int(string)
        }
        return nil
    }

    private static func parseDouble(_ value: JSONValue?) -> Double? {
        if let number = value?.numberValue {
            return number
        }
        if let string = value?.stringValue {
            return Double(string)
        }
        return nil
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
