import Foundation

// MARK: - Agents & Schedules

extension APIClient {
    func uploadIconAsset(data body: Data, contentType: String) async throws -> IconAssetRecord {
        let (data, response) = try await request(
            "POST",
            path: "/icon-assets",
            body: body,
            contentType: contentType
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(IconAssetUploadResponse.self, from: data).asset
    }

    func fetchIconAsset(assetId: String) async throws -> Data {
        let encodedAssetId = try percentEncodePathSegment(assetId)
        return try await get("/icon-assets/\(encodedAssetId)")
    }

    func listAgents(includeArchived: Bool = false) async throws -> [AgentDefinitionSummary] {
        let suffix = includeArchived ? "?includeArchived=true" : ""
        return try await get("/agents\(suffix)", as: AgentListResponse.self).agents
    }

    func getAgent(_ agentId: String) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        return try await get("/agents/\(encodedAgentId)", as: AgentResponse.self).agent
    }

    func createAgent(_ definition: AgentDefinition) async throws -> StoredAgentDefinition {
        try await post("/agents", body: definition, as: AgentResponse.self).agent
    }

    func updateAgent(
        agentId: String,
        definition: AgentDefinition,
        previouslyHadLaunchConstraints: Bool = false
    ) async throws -> StoredAgentDefinition {
        struct UpdateBody: Encodable {
            let definition: AgentDefinition
            let includesLaunchConstraints: Bool

            enum CodingKeys: String, CodingKey {
                case name, icon, description, instructions, resources, sessionDefaults, launchConstraints
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(definition.name, forKey: .name)
                try c.encode(definition.icon, forKey: .icon)
                try c.encodeNullable(definition.description, forKey: .description)
                try c.encodeNullable(definition.instructions, forKey: .instructions)
                try c.encodeNullable(definition.resources, forKey: .resources)
                try c.encodeNullable(definition.sessionDefaults, forKey: .sessionDefaults)
                if includesLaunchConstraints {
                    try c.encodeNullable(definition.launchConstraints, forKey: .launchConstraints)
                }
            }
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        return try await patch(
            "/agents/\(encodedAgentId)",
            body: UpdateBody(
                definition: definition,
                includesLaunchConstraints: definition.launchConstraints != nil
                    || previouslyHadLaunchConstraints
            ),
            as: AgentResponse.self
        ).agent
    }

    /// CAS patch so a model-star tap cannot overwrite a concurrent Agent edit.
    func setAgentDefaultModel(
        agentId: String,
        version: Int,
        model: String
    ) async throws -> StoredAgentDefinition {
        struct Defaults: Encodable { let model: String }
        struct Patch: Encodable { let sessionDefaults: Defaults }
        let encodedId = try percentEncodePathSegment(agentId)
        return try await patch(
            "/agents/\(encodedId)?expectedVersion=\(version)",
            body: Patch(sessionDefaults: Defaults(model: model)),
            as: AgentResponse.self
        ).agent
    }

    /// CAS patch of an Agent's prompt alone, as the in-app editor writes it: the
    /// text and its append/replace mode, nothing else. An empty text clears the
    /// custom prompt instead of failing validation (the server refuses an empty one).
    func updateAgentInstructions(
        agentId: String,
        expectedVersion: Int,
        mode: AgentInstructionMode,
        text: String
    ) async throws -> StoredAgentDefinition {
        struct Instructions: Encodable {
            let mode: AgentInstructionMode
            let text: String
        }
        struct Patch: Encodable {
            let instructions: Instructions?

            private enum CodingKeys: String, CodingKey { case instructions }

            // An empty prompt must reach the server as an explicit null (which
            // clears the custom prompt), not as an omitted field.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let instructions {
                    try c.encode(instructions, forKey: .instructions)
                } else {
                    try c.encodeNil(forKey: .instructions)
                }
            }
        }
        let encodedId = try percentEncodePathSegment(agentId)
        let patchBody = Patch(
            instructions: text.isEmpty ? nil : Instructions(mode: mode, text: text)
        )
        return try await patch(
            "/agents/\(encodedId)?expectedVersion=\(expectedVersion)",
            body: patchBody,
            as: AgentResponse.self
        ).agent
    }

    /// CAS patch of a Schedule's prompt alone. The prompt is required, so the
    /// server refuses an empty one.
    func updateAgentSchedulePrompt(
        scheduleId: String,
        expectedVersion: Int,
        prompt: String
    ) async throws -> AgentScheduleSummary {
        struct Action: Encodable { let prompt: String }
        struct Patch: Encodable { let action: Action }
        let encodedId = try percentEncodePathSegment(scheduleId)
        return try await patch(
            "/schedules/\(encodedId)?expectedVersion=\(expectedVersion)",
            body: Patch(action: Action(prompt: prompt)),
            as: AgentScheduleSummaryResponse.self
        ).schedule
    }

    func updateAgentNative(
        agentId: String,
        name: String,
        description: String?,
        instructions: AgentInstructions?,
        model: String?,
        thinkingLevel: ThinkingLevel?,
        skillPaths: [String]?,
        extensionIds: [String]?,
        launchConstraints: AgentLaunchConstraints? = nil,
        previouslyHadLaunchConstraints: Bool = false,
        tools: [String]? = nil,
        excludeTools: [String]? = nil,
        noTools: AgentNoToolsMode? = nil,
        expectedVersion: Int? = nil
    ) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        let query = expectedVersion.map { "?expectedVersion=\($0)" } ?? ""
        return try await patch(
            "/agents/\(encodedAgentId)\(query)",
            body: NativeAgentUpdateBody(
                name: name,
                description: description,
                instructions: instructions,
                resources: .init(skillPaths: skillPaths, extensionIds: extensionIds),
                sessionDefaults: .init(
                    model: model,
                    thinkingLevel: thinkingLevel,
                    includesToolPolicy: true,
                    tools: tools,
                    excludeTools: excludeTools,
                    noTools: noTools
                ),
                launchConstraints: launchConstraints,
                includesLaunchConstraints: launchConstraints != nil
                    || previouslyHadLaunchConstraints
            ),
            as: AgentResponse.self
        ).agent
    }

    func updateAgentIcon(agentId: String, icon: IconChoice) async throws -> StoredAgentDefinition {
        struct IconUpdateBody: Encodable {
            let icon: IconChoice
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        return try await patch("/agents/\(encodedAgentId)", body: IconUpdateBody(icon: icon), as: AgentResponse.self).agent
    }

    func archiveAgent(agentId: String) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        return try await delete("/agents/\(encodedAgentId)", as: AgentResponse.self).agent
    }

    func launchAgentSession(
        agentId: String,
        prompt: String?,
        workspaceId: String,
        worktreeId: String? = nil,
        model: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        sessionName: String? = nil,
        engine: SessionEngine = .classic,
        idempotencyKey: String = "ios-agent-launch-\(UUID().uuidString)"
    ) async throws -> AgentSessionLaunchResponse {
        struct PromptBody: Encodable {
            let text: String
        }
        struct TargetBody: Encodable {
            let workspaceId: String
            let worktreeId: String?
        }
        struct OverridesBody: Encodable {
            let model: String?
            let thinkingLevel: ThinkingLevel?
        }
        struct Body: Encodable {
            let prompt: PromptBody?
            let target: TargetBody
            let overrides: OverridesBody?
            let sessionName: String?
            let engine: SessionEngine?
            let idempotencyKey: String
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrides = (cleanModel?.isEmpty == false || thinkingLevel != nil)
            ? OverridesBody(model: cleanModel?.isEmpty == false ? cleanModel : nil, thinkingLevel: thinkingLevel)
            : nil
        let body = Body(
            prompt: prompt?.nilIfBlank.map { PromptBody(text: $0) },
            target: TargetBody(workspaceId: workspaceId, worktreeId: worktreeId?.nilIfBlank),
            overrides: overrides,
            sessionName: sessionName?.nilIfBlank,
            engine: engine == .durable ? engine : nil,
            idempotencyKey: idempotencyKey
        )
        let (data, response) = try await request(
            "POST",
            path: "/agents/\(encodedAgentId)/sessions",
            body: body
        )
        if let http = response as? HTTPURLResponse,
           http.statusCode == 422,
           let failure = try? JSONDecoder().decode(AgentLaunchFailureResponse.self, from: data) {
            throw failure
        }
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(AgentSessionLaunchResponse.self, from: data)
    }

    func listAgentSchedules(status: AgentScheduleStatus? = nil) async throws -> [AgentScheduleSummary] {
        let suffix = status.map { "?status=\($0.rawValue)" } ?? ""
        return try await get("/schedules\(suffix)", as: AgentScheduleListResponse.self).schedules
    }

    /// Past runs with their sessions' outcomes and upcoming occurrences in `[from, to)`, at most
    /// 62 days (`capabilities.scheduleCalendar`).
    func scheduleCalendar(from: Date, to: Date) async throws -> ScheduleCalendarResponse {
        let fromMs = Int64((from.timeIntervalSince1970 * 1000).rounded(.down))
        let toMs = Int64((to.timeIntervalSince1970 * 1000).rounded(.down))
        return try await get("/schedules/calendar?from=\(fromMs)&to=\(toMs)", as: ScheduleCalendarResponse.self)
    }

    func getAgentSchedule(_ scheduleId: String) async throws -> AgentSchedule {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        return try await get("/schedules/\(encodedScheduleId)", as: AgentScheduleResponse.self).schedule
    }

    func createAgentSchedule(
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction
    ) async throws -> AgentScheduleSummary {
        struct Body: Encodable {
            let name: String
            let trigger: AgentScheduleTrigger
            let action: AgentScheduleAction
        }
        return try await post(
            "/schedules",
            body: Body(name: name, trigger: trigger, action: action),
            as: AgentScheduleSummaryResponse.self
        ).schedule
    }

    func updateAgentSchedule(
        scheduleId: String,
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction
    ) async throws -> AgentScheduleSummary {
        struct Body: Encodable {
            let name: String
            let trigger: AgentScheduleTrigger
            let action: AgentScheduleAction
        }
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        return try await patch(
            "/schedules/\(encodedScheduleId)",
            body: Body(name: name, trigger: trigger, action: action),
            as: AgentScheduleSummaryResponse.self
        ).schedule
    }

    func updateAgentScheduleNative(
        scheduleId: String,
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction,
        expectedVersion: Int? = nil
    ) async throws -> AgentScheduleSummary {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let query = expectedVersion.map { "?expectedVersion=\($0)" } ?? ""
        return try await patch(
            "/schedules/\(encodedScheduleId)\(query)",
            body: NativeScheduleUpdateBody(
                name: name,
                trigger: trigger,
                action: NativeScheduleActionUpdate(action)
            ),
            as: AgentScheduleSummaryResponse.self
        ).schedule
    }

    func pauseAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleSummary {
        try await scheduleStateMutation(scheduleId: scheduleId, action: "pause")
    }

    func resumeAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleSummary {
        try await scheduleStateMutation(scheduleId: scheduleId, action: "resume")
    }

    func archiveAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleSummary {
        try await scheduleStateMutation(scheduleId: scheduleId, action: "archive")
    }

    func restoreAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleSummary {
        try await scheduleStateMutation(scheduleId: scheduleId, action: "restore")
    }

    func runAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleRunSummary {
        struct Body: Encodable {
            let requestId: String
        }
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        return try await post(
            "/schedules/\(encodedScheduleId)/run",
            body: Body(requestId: "ios-manual-\(UUID().uuidString)"),
            as: AgentScheduleRunResponse.self
        ).run
    }

    func listAgentScheduleRuns(scheduleId: String, limit: Int = 20) async throws -> [AgentScheduleRunSummary] {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let runs = try await get(
            "/schedules/\(encodedScheduleId)/runs?limit=\(limit)&order=desc",
            as: AgentScheduleRunsResponse.self
        ).runs
        return runs.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    private func scheduleStateMutation(scheduleId: String, action: String) async throws -> AgentScheduleSummary {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        return try await post(
            "/schedules/\(encodedScheduleId)/\(action)",
            body: EmptyBody(),
            as: AgentScheduleSummaryResponse.self
        ).schedule
    }
}

private struct NativeAgentUpdateBody: Encodable {
    struct Resources: Encodable {
        let skillPaths: [String]?
        let extensionIds: [String]?

        enum CodingKeys: String, CodingKey {
            case skillPaths, promptTemplateIds, extensionIds
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(skillPaths, forKey: .skillPaths)
            // Clear assignments written by older app/server versions.
            try container.encodeNil(forKey: .promptTemplateIds)
            try container.encodeNullable(extensionIds, forKey: .extensionIds)
        }
    }

    struct SessionDefaults: Encodable {
        let model: String?
        let thinkingLevel: ThinkingLevel?
        let includesToolPolicy: Bool
        let tools: [String]?
        let excludeTools: [String]?
        let noTools: AgentNoToolsMode?

        enum CodingKeys: String, CodingKey {
            case model, thinkingLevel, tools, excludeTools, noTools
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(model, forKey: .model)
            try container.encodeNullable(thinkingLevel, forKey: .thinkingLevel)
            if includesToolPolicy {
                try container.encodeNullable(tools, forKey: .tools)
                try container.encodeNullable(excludeTools, forKey: .excludeTools)
                try container.encodeNullable(noTools, forKey: .noTools)
            }
        }
    }

    let name: String
    let description: String?
    let instructions: AgentInstructions?
    let resources: Resources?
    let sessionDefaults: SessionDefaults
    let launchConstraints: AgentLaunchConstraints?
    let includesLaunchConstraints: Bool

    /// The server merges launch constraints key by key, so a cleared constraint is sent as
    /// null; an omitted key would keep its stored value.
    struct LaunchConstraints: Encodable {
        let constraints: AgentLaunchConstraints

        enum CodingKeys: String, CodingKey {
            case allowedWorkspaceIds, requiredRuntime, requiredEngine
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(constraints.allowedWorkspaceIds, forKey: .allowedWorkspaceIds)
            try container.encodeNullable(constraints.requiredRuntime, forKey: .requiredRuntime)
            try container.encodeNullable(constraints.requiredEngine, forKey: .requiredEngine)
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, description, instructions, resources, sessionDefaults, launchConstraints
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeNullable(description, forKey: .description)
        try container.encodeNullable(instructions, forKey: .instructions)
        try container.encodeIfPresent(resources, forKey: .resources)
        try container.encode(sessionDefaults, forKey: .sessionDefaults)
        if includesLaunchConstraints {
            try container.encodeNullable(launchConstraints.map(LaunchConstraints.init), forKey: .launchConstraints)
        }
    }
}

private struct NativeScheduleUpdateBody: Encodable {
    let name: String
    let trigger: AgentScheduleTrigger
    let action: NativeScheduleActionUpdate
}

private struct NativeScheduleActionUpdate: Encodable {
    let action: AgentScheduleAction

    init(_ action: AgentScheduleAction) {
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId, sessionId, prompt, agentId, model, thinkingLevel, name, streamingBehavior
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch action {
        case .newSession(
            let workspaceId,
            let prompt,
            let agentId,
            let model,
            let thinkingLevel,
            _,
            let name
        ):
            try container.encode(workspaceId, forKey: .workspaceId)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeNullable(agentId, forKey: .agentId)
            try container.encodeNullable(model, forKey: .model)
            try container.encodeNullable(thinkingLevel, forKey: .thinkingLevel)
            try container.encodeNullable(name, forKey: .name)
        case .existingSession(let workspaceId, let sessionId, let prompt, let streamingBehavior):
            try container.encode(workspaceId, forKey: .workspaceId)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeNullable(streamingBehavior, forKey: .streamingBehavior)
        }
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
