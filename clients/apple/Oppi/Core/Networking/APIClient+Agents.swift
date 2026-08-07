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
        let data = try await get("/agents\(suffix)")
        return try JSONDecoder().decode(AgentListResponse.self, from: data).agents
    }

    func getAgent(_ agentId: String) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        let data = try await get("/agents/\(encodedAgentId)")
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func createAgent(_ definition: AgentDefinition) async throws -> StoredAgentDefinition {
        let data = try await post("/agents", body: definition)
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
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
                try encodeNullable(definition.description, to: &c, forKey: .description)
                try encodeNullable(definition.instructions, to: &c, forKey: .instructions)
                try encodeNullable(definition.resources, to: &c, forKey: .resources)
                try encodeNullable(definition.sessionDefaults, to: &c, forKey: .sessionDefaults)
                if includesLaunchConstraints {
                    try encodeNullable(definition.launchConstraints, to: &c, forKey: .launchConstraints)
                }
            }

            func encodeNullable<T: Encodable>(
                _ value: T?,
                to container: inout KeyedEncodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) throws {
                if let value {
                    try container.encode(value, forKey: key)
                } else {
                    try container.encodeNil(forKey: key)
                }
            }
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        let data = try await patch(
            "/agents/\(encodedAgentId)",
            body: UpdateBody(
                definition: definition,
                includesLaunchConstraints: definition.launchConstraints != nil
                    || previouslyHadLaunchConstraints
            )
        )
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
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
        previouslyHadLaunchConstraints: Bool = false
    ) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        let data = try await patch(
            "/agents/\(encodedAgentId)",
            body: NativeAgentUpdateBody(
                name: name,
                description: description,
                instructions: instructions,
                // The server-owned Oppi agent accepts only identity,
                // instructions, and session-default customization fields.
                resources: agentId == "oppi-default-agent"
                    ? nil
                    : .init(skillPaths: skillPaths, extensionIds: extensionIds),
                sessionDefaults: .init(model: model, thinkingLevel: thinkingLevel),
                launchConstraints: launchConstraints,
                includesLaunchConstraints: agentId != "oppi-default-agent"
                    && (launchConstraints != nil || previouslyHadLaunchConstraints)
            )
        )
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func updateAgentIcon(agentId: String, icon: IconChoice) async throws -> StoredAgentDefinition {
        struct IconUpdateBody: Encodable {
            let icon: IconChoice
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        let data = try await patch(
            "/agents/\(encodedAgentId)",
            body: IconUpdateBody(icon: icon)
        )
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func archiveAgent(agentId: String) async throws -> StoredAgentDefinition {
        let encodedAgentId = try percentEncodePathSegment(agentId)
        let data = try await delete("/agents/\(encodedAgentId)")
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func launchAgentSession(
        agentId: String,
        prompt: String,
        workspaceId: String,
        worktreeId: String? = nil,
        model: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        sessionName: String? = nil
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
            let prompt: PromptBody
            let target: TargetBody
            let overrides: OverridesBody?
            let sessionName: String?
            let idempotencyKey: String
        }

        let encodedAgentId = try percentEncodePathSegment(agentId)
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrides = (cleanModel?.isEmpty == false || thinkingLevel != nil)
            ? OverridesBody(model: cleanModel?.isEmpty == false ? cleanModel : nil, thinkingLevel: thinkingLevel)
            : nil
        let body = Body(
            prompt: PromptBody(text: prompt),
            target: TargetBody(workspaceId: workspaceId, worktreeId: worktreeId?.nilIfBlank),
            overrides: overrides,
            sessionName: sessionName?.nilIfBlank,
            idempotencyKey: "ios-agent-launch-\(UUID().uuidString)"
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
        let data = try await get("/schedules\(suffix)")
        return try JSONDecoder().decode(AgentScheduleListResponse.self, from: data).schedules
    }

    func getAgentSchedule(_ scheduleId: String) async throws -> AgentSchedule {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let data = try await get("/schedules/\(encodedScheduleId)")
        return try JSONDecoder().decode(AgentScheduleResponse.self, from: data).schedule
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
        let data = try await post("/schedules", body: Body(name: name, trigger: trigger, action: action))
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
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
        let data = try await patch(
            "/schedules/\(encodedScheduleId)",
            body: Body(name: name, trigger: trigger, action: action)
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }

    func updateAgentScheduleNative(
        scheduleId: String,
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction
    ) async throws -> AgentScheduleSummary {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let data = try await patch(
            "/schedules/\(encodedScheduleId)",
            body: NativeScheduleUpdateBody(
                name: name,
                trigger: trigger,
                action: NativeScheduleActionUpdate(action)
            )
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
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
        let data = try await post(
            "/schedules/\(encodedScheduleId)/run",
            body: Body(requestId: "ios-manual-\(UUID().uuidString)")
        )
        return try JSONDecoder().decode(AgentScheduleRunResponse.self, from: data).run
    }

    func listAgentScheduleRuns(scheduleId: String, limit: Int = 20) async throws -> [AgentScheduleRunSummary] {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let data = try await get("/schedules/\(encodedScheduleId)/runs?limit=\(limit)")
        return try JSONDecoder().decode(AgentScheduleRunsResponse.self, from: data).runs
    }

    private func scheduleStateMutation(scheduleId: String, action: String) async throws -> AgentScheduleSummary {
        let encodedScheduleId = try percentEncodePathSegment(scheduleId)
        let data = try await post("/schedules/\(encodedScheduleId)/\(action)", body: APIClientEmptyBody())
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }
}

private extension APIClient {
    func patch<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let (data, response) = try await request("PATCH", path: path, body: body)
        try checkStatus(response, data: data)
        return data
    }

    func delete(_ path: String) async throws -> Data {
        let (data, response) = try await request("DELETE", path: path)
        try checkStatus(response, data: data)
        return data
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

        enum CodingKeys: String, CodingKey { case model, thinkingLevel }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(model, forKey: .model)
            try container.encodeNullable(thinkingLevel, forKey: .thinkingLevel)
        }
    }

    let name: String
    let description: String?
    let instructions: AgentInstructions?
    let resources: Resources?
    let sessionDefaults: SessionDefaults
    let launchConstraints: AgentLaunchConstraints?
    let includesLaunchConstraints: Bool

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
            try container.encodeNullable(launchConstraints, forKey: .launchConstraints)
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

private struct APIClientEmptyBody: Encodable {}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
