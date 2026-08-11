import Foundation

struct SharedSessionLink: Sendable, Equatable {
    let shareURL: String
    let gistURL: String
    let gistID: String
}

struct ShareSessionRedactionFinding: Sendable, Equatable {
    let kind: String
    let count: Int
    let replacement: String
    let samples: [String]
}

struct ShareSessionRedactionReport: Sendable, Equatable {
    let policy: ShareSessionRedactionPolicy?
    let totalReplacements: Int
    let findings: [ShareSessionRedactionFinding]
}

struct SharedSessionPublishResult: Sendable, Equatable {
    let link: SharedSessionLink
    let redaction: ShareSessionRedactionReport?
}

struct ShareSessionScanFinding: Sendable, Equatable {
    let kind: String
    let count: Int
}

struct ShareSessionPrepareResult: Sendable, Equatable {
    let canPublish: Bool
    let blocked: Bool
    let findings: [ShareSessionScanFinding]
    let artifactBytes: Int?
    let redaction: ShareSessionRedactionReport?
}

enum ShareSessionRequestError: LocalizedError {
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Share request timed out. Please try again."
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Model, Thinking, and Slash Commands

extension ServerConnection {
    // ── Model ──

    func setModel(provider: String, modelId: String) async throws {
        try await waitForFocusedFullSubscriptionIfNeeded()
        _ = try await sendCommandAwaitingResult(command: "set_model") { requestId in
            .setModel(provider: provider, modelId: modelId, requestId: requestId)
        }
    }

    // periphery:ignore - API surface for model cycling
    func cycleModel() async throws {
        try await send(.cycleModel())
    }

    // ── Thinking ──

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        try await waitForFocusedFullSubscriptionIfNeeded()
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

    private func waitForFocusedFullSubscriptionIfNeeded() async throws {
        guard let sessionId = focusedSessionId else {
            throw WebSocketError.notConnected
        }
        guard await waitForFocusedFullSubscription(sessionId: sessionId, timeout: .seconds(3)) else {
            throw WebSocketError.notConnected
        }
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

    func reloadResources() async throws {
        _ = try await sendCommandAwaitingResult(command: "reload") { requestId in
            .reload(requestId: requestId)
        }
    }

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

    func prepareShareSession(
        redactionPolicy: ShareSessionRedactionPolicy? = nil
    ) async throws -> ShareSessionPrepareResult? {
        let startedAtMs = ChatSessionTelemetry.nowMs()
        let policy = redactionPolicy?.normalized
        let sessionId = focusedSessionId
        let workspaceId = sessionId.flatMap { sessionStore.workspaceId(for: $0) }

        do {
            let data = try await sendCommandAwaitingResult(command: "share_session") { requestId in
                .shareSession(
                    action: .prepare,
                    redactionPolicy: policy,
                    requestId: requestId
                )
            }
            let parsed = Self.parseShareSessionPrepareResult(from: data)
            var tags = Self.shareTelemetryTags(policy: policy)
            tags["status"] = "ok"
            if let parsed {
                tags["blocked"] = parsed.blocked ? "1" : "0"
                tags["can_publish"] = parsed.canPublish ? "1" : "0"
                tags["findings"] = String(parsed.findings.count)
                tags["replacements"] = String(parsed.redaction?.totalReplacements ?? 0)
            }
            ChatSessionTelemetry.recordTimingMetric(
                .sharePrepareMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
            return parsed
        } catch let commandError as CommandRequestError {
            let normalized = Self.normalizeShareSessionError(commandError)
            var tags = Self.shareTelemetryTags(policy: policy)
            tags["status"] = "error"
            tags["error_kind"] = ChatSessionTelemetry.metricErrorKind(for: normalized)
            ChatSessionTelemetry.recordTimingMetric(
                .sharePrepareMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
            ChatSessionTelemetry.recordCountMetric(
                .shareError,
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: ["action": "prepare", "error_kind": ChatSessionTelemetry.metricErrorKind(for: normalized)]
            )
            throw normalized
        }
    }

    func shareSession(
        redactionPolicy: ShareSessionRedactionPolicy? = nil
    ) async throws -> SharedSessionPublishResult? {
        let startedAtMs = ChatSessionTelemetry.nowMs()
        let policy = redactionPolicy?.normalized
        let sessionId = focusedSessionId
        let workspaceId = sessionId.flatMap { sessionStore.workspaceId(for: $0) }

        do {
            let data = try await sendCommandAwaitingResult(command: "share_session") { requestId in
                .shareSession(
                    action: .publish,
                    redactionPolicy: policy,
                    requestId: requestId
                )
            }
            let parsed = Self.parseShareSessionPublishResult(from: data)
            var tags = Self.shareTelemetryTags(policy: policy)
            tags["status"] = "ok"
            if let parsed {
                tags["findings"] = String(parsed.redaction?.findings.count ?? 0)
                tags["replacements"] = String(parsed.redaction?.totalReplacements ?? 0)
            }
            ChatSessionTelemetry.recordTimingMetric(
                .sharePublishMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
            return parsed
        } catch let commandError as CommandRequestError {
            let normalized = Self.normalizeShareSessionError(commandError)
            var tags = Self.shareTelemetryTags(policy: policy)
            tags["status"] = "error"
            tags["error_kind"] = ChatSessionTelemetry.metricErrorKind(for: normalized)
            ChatSessionTelemetry.recordTimingMetric(
                .sharePublishMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
            ChatSessionTelemetry.recordCountMetric(
                .shareError,
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: ["action": "publish", "error_kind": ChatSessionTelemetry.metricErrorKind(for: normalized)]
            )
            throw normalized
        }
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

    static func shareTelemetryTags(policy: ShareSessionRedactionPolicy?) -> [String: String] {
        let normalized = (policy ?? .recommended).normalized
        return [
            "emails": normalized.emails ? "1" : "0",
            "phones": normalized.phones ? "1" : "0",
            "user_paths": normalized.userPaths ? "1" : "0",
            "ip_addresses": normalized.ipAddresses ? "1" : "0",
            "jwt_bearer": normalized.jwtAndBearer ? "1" : "0",
            "names": normalized.namesHeuristic ? "1" : "0",
            "skills": normalized.skills ? "1" : "0",
        ]
    }

    static func normalizeShareSessionError(_ error: CommandRequestError) -> ShareSessionRequestError {
        switch error {
        case .timeout:
            return .timedOut
        case .rejected(_, let reason):
            let envelope = parseShareErrorEnvelope(reason)
            return .failed(shareErrorMessage(code: envelope.code, fallback: envelope.message))
        }
    }

    static func parseShareErrorEnvelope(_ reason: String?) -> (code: String?, message: String?) {
        guard let reason else { return (nil, nil) }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[share:"),
              let closeBracket = trimmed.firstIndex(of: "]") else {
            return (nil, trimmed.isEmpty ? nil : trimmed)
        }

        let codeStart = trimmed.index(trimmed.startIndex, offsetBy: "[share:".count)
        let rawCode = String(trimmed[codeStart..<closeBracket]).trimmingCharacters(in: .whitespacesAndNewlines)

        let messageStart = trimmed.index(after: closeBracket)
        let rawMessage = String(trimmed[messageStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            rawCode.isEmpty ? nil : rawCode,
            rawMessage.isEmpty ? nil : rawMessage
        )
    }

    static func shareErrorMessage(code: String?, fallback: String?) -> String {
        switch code {
        case "gh_not_installed":
            return "Server is missing GitHub CLI (gh). Install it and try again."
        case "gh_not_authenticated":
            return "GitHub CLI is not logged in on the server. Run 'gh auth login' and retry."
        case "share_timeout":
            return "Share request timed out. Please try again."
        case "share_secret_detected":
            return fallback ?? "Share blocked because potential secrets were detected."
        case "session_not_persisted":
            return "This session cannot be shared yet because it has no persisted session file."
        case "gist_create_failed":
            return fallback ?? "Failed to create GitHub gist. Check server auth and network."
        case "gist_parse_failed":
            return fallback ?? "Share upload completed but the server could not parse gist metadata."
        default:
            return fallback ?? "Share failed."
        }
    }

    static func parseShareSessionPrepareResult(from data: JSONValue?) -> ShareSessionPrepareResult? {
        guard let object = data?.objectValue,
              object["phase"]?.stringValue == "prepared" else {
            return nil
        }

        let canPublish = object["canPublish"]?.boolValue ?? false
        let scan = object["scan"]?.objectValue
        let blocked = scan?["blocked"]?.boolValue ?? false
        let findings = scan?["findings"]?.arrayValue?.compactMap { value -> ShareSessionScanFinding? in
            guard let finding = value.objectValue,
                  let kind = finding["kind"]?.stringValue,
                  !kind.isEmpty else {
                return nil
            }
            let count = parseInt(finding["count"]) ?? 0
            return ShareSessionScanFinding(kind: kind, count: count)
        } ?? []

        let artifactBytes = parseInt(object["artifact"]?.objectValue?["bytes"])

        return ShareSessionPrepareResult(
            canPublish: canPublish,
            blocked: blocked,
            findings: findings,
            artifactBytes: artifactBytes,
            redaction: parseShareSessionRedactionReport(from: data)
        )
    }

    static func parseShareSessionRedactionPolicy(from value: JSONValue?) -> ShareSessionRedactionPolicy? {
        guard let object = value?.objectValue else { return nil }

        func bool(_ key: String, fallback: Bool) -> Bool {
            object[key]?.boolValue ?? fallback
        }

        return ShareSessionRedactionPolicy(
            secrets: true,
            emails: bool("emails", fallback: ShareSessionRedactionPolicy.recommended.emails),
            phones: bool("phones", fallback: ShareSessionRedactionPolicy.recommended.phones),
            userPaths: bool("userPaths", fallback: ShareSessionRedactionPolicy.recommended.userPaths),
            ipAddresses: bool("ipAddresses", fallback: ShareSessionRedactionPolicy.recommended.ipAddresses),
            jwtAndBearer: bool("jwtAndBearer", fallback: ShareSessionRedactionPolicy.recommended.jwtAndBearer),
            namesHeuristic: bool("namesHeuristic", fallback: ShareSessionRedactionPolicy.recommended.namesHeuristic),
            skills: bool("skills", fallback: ShareSessionRedactionPolicy.recommended.skills)
        )
    }

    static func parseShareSessionRedactionReport(from data: JSONValue?) -> ShareSessionRedactionReport? {
        guard let object = data?.objectValue,
              let redactionObject = object["redaction"]?.objectValue else {
            return nil
        }

        let totalReplacements = parseInt(redactionObject["totalReplacements"]) ?? 0
        let findings = redactionObject["findings"]?.arrayValue?.compactMap { value -> ShareSessionRedactionFinding? in
            guard let finding = value.objectValue,
                  let kind = finding["kind"]?.stringValue,
                  !kind.isEmpty else {
                return nil
            }

            let count = parseInt(finding["count"]) ?? 0
            let replacement = finding["replacement"]?.stringValue ?? "[REDACTED]"
            let samples = finding["samples"]?.arrayValue?.compactMap { sample in
                sample.stringValue
            } ?? []

            return ShareSessionRedactionFinding(
                kind: kind,
                count: count,
                replacement: replacement,
                samples: samples
            )
        } ?? []

        return ShareSessionRedactionReport(
            policy: parseShareSessionRedactionPolicy(from: redactionObject["policy"]),
            totalReplacements: totalReplacements,
            findings: findings
        )
    }

    static func parseShareSessionPublishResult(from data: JSONValue?) -> SharedSessionPublishResult? {
        guard let link = parseSharedSessionLink(from: data) else {
            return nil
        }

        return SharedSessionPublishResult(
            link: link,
            redaction: parseShareSessionRedactionReport(from: data)
        )
    }

    static func parseSharedSessionLink(from data: JSONValue?) -> SharedSessionLink? {
        guard let object = data?.objectValue else {
            return nil
        }

        let shareObject = object["share"]?.objectValue
        let providerRef = shareObject?["providerRef"]?.objectValue

        let shareURLRaw = object["shareUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? shareObject?["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        let gistURLRaw = object["gistUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? providerRef?["gistUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        let gistIDRaw = object["gistId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? providerRef?["gistId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let shareURLRaw, !shareURLRaw.isEmpty,
              let gistURLRaw, !gistURLRaw.isEmpty,
              let gistIDRaw, !gistIDRaw.isEmpty else {
            return nil
        }

        return SharedSessionLink(
            shareURL: shareURLRaw,
            gistURL: gistURLRaw,
            gistID: gistIDRaw
        )
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
            cacheWaste: parseCacheWaste(root["cacheWaste"]),
            modelBreakdown: parseModelBreakdown(root["modelBreakdown"]),
            contextComposition: parseContextComposition(root["contextComposition"]),
            loadedResources: parseLoadedResources(root["loadedResources"])
        )
    }

    private static func parseCacheWaste(_ value: JSONValue?) -> SessionCacheWasteSnapshot? {
        guard let object = value?.objectValue else { return nil }
        return SessionCacheWasteSnapshot(
            missedTokens: parseInt(object["missedTokens"]) ?? 0,
            missedCost: parseDouble(object["missedCost"]) ?? 0,
            missCount: parseInt(object["missCount"]) ?? 0
        )
    }

    private static func parseModelBreakdown(_ value: JSONValue?) -> [SessionModelUsageSnapshot] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let model = object["model"]?.stringValue else {
                return nil
            }
            return SessionModelUsageSnapshot(
                provider: object["provider"]?.stringValue,
                model: model,
                tokens: parseInt(object["tokens"]) ?? 0,
                cost: parseDouble(object["cost"]) ?? 0
            )
        } ?? []
    }

    private static func parseLoadedResources(_ value: JSONValue?) -> SessionLoadedResourcesSnapshot? {
        guard let object = value?.objectValue else { return nil }
        return SessionLoadedResourcesSnapshot(
            skills: parseResourceList(object["skills"]),
            extensions: parseResourceList(object["extensions"])
        )
    }

    private static func parseResourceList(_ value: JSONValue?) -> [SessionResourceSnapshot] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            return SessionResourceSnapshot(
                name: name,
                description: object["description"]?.stringValue,
                path: object["path"]?.stringValue ?? ""
            )
        } ?? []
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
