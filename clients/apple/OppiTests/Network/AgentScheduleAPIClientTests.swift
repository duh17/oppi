import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping non_optional_string_data_conversion

@Suite("Agent and schedule API client", .serialized)
struct AgentScheduleAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func cleanup() {
        TestURLProtocol.handler = nil
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private func requestBodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }

    @Test func agentListDecodesSavedIconSummary() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/agents")
            return mockResponse(json: """
            {"agents":[{"id":"agent-1","name":"Sensei","icon":"🧘","status":"active","version":2,"createdAt":1000,"updatedAt":2000}]}
            """)
        }

        let agents = try await client.listAgents()

        #expect(agents.count == 1)
        #expect(agents.first?.icon == "🧘")
    }

    @Test func agentCreatePostsDefinitionAndDecodesStoredAgent() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents")
            let body = try JSONDecoder().decode(AgentDefinition.self, from: requestBodyData(request))
            #expect(body.name == "Reviewer")
            #expect(body.instructions?.mode == .append)
            #expect(body.sessionDefaults?.thinkingLevel == .medium)
            return mockResponse(status: 201, json: """
            {"agent":{"id":"agent-1","name":"Reviewer","icon":"🧘","status":"active","version":1,"definition":{"name":"Reviewer","icon":"🧘","instructions":{"mode":"append","text":"Review changes."},"sessionDefaults":{"thinkingLevel":"medium"}},"createdAt":1000,"updatedAt":1000}}
            """)
        }

        let agent = try await client.createAgent(
            AgentDefinition(
                name: "Reviewer",
                instructions: AgentInstructions(text: "Review changes."),
                sessionDefaults: AgentSessionDefaults(thinkingLevel: .medium)
            )
        )

        #expect(agent.id == "agent-1")
        #expect(agent.icon == "🧘")
        #expect(agent.definition.icon == "🧘")
        #expect(agent.definition.instructions?.text == "Review changes.")
        #expect(agent.createdAt == Date(timeIntervalSince1970: 1))
    }

    @Test func agentUpdateSendsNullsForClearedOptionalFields() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let json = try JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            #expect(json?["name"] as? String == "Reviewer")
            #expect(json?["icon"] is NSNull)
            #expect(json?["description"] is NSNull)
            #expect(json?["instructions"] is NSNull)
            #expect(json?["resources"] is NSNull)
            #expect(json?["sessionDefaults"] is NSNull)
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":2,"definition":{"name":"Reviewer"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let agent = try await client.updateAgent(
            agentId: "agent-1",
            definition: AgentDefinition(name: "Reviewer")
        )

        #expect(agent.version == 2)
        #expect(agent.definition.description == nil)
    }

    @Test func agentIconUpdateSendsOnlyIconForSetAndClear() async throws {
        let client = makeClient()
        defer { cleanup() }

        var expectedIcon: String? = "🧘"
        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(Set(json.keys) == ["icon"])
            if let expectedIcon {
                #expect(json["icon"] as? String == expectedIcon)
            } else {
                #expect(json["icon"] is NSNull)
            }
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":\(requestCount + 1),"definition":{"name":"Reviewer"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        _ = try await client.updateAgentIcon(agentId: "agent-1", icon: "🧘")
        expectedIcon = nil
        _ = try await client.updateAgentIcon(agentId: "agent-1", icon: nil)

        #expect(requestCount == 2)
    }

    @Test func scheduleDetailDecodesFullPromptAndAction() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/schedules/sch-1")
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Run QA","agentId":"agent-1","model":"openai/gpt-5.5","worktreeId":"wt-1","name":"QA run"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let schedule = try await client.getAgentSchedule("sch-1")

        #expect(schedule.name == "Daily QA")
        #expect(schedule.trigger.displaySummary.contains("0 9 * * *"))
        guard case .newSession(let workspaceId, let prompt, let agentId, let model, let worktreeId, let name) = schedule.action else {
            Issue.record("Expected new-session action")
            return
        }
        #expect(workspaceId == "ws-1")
        #expect(prompt == "Run QA")
        #expect(agentId == "agent-1")
        #expect(model == "openai/gpt-5.5")
        #expect(worktreeId == "wt-1")
        #expect(name == "QA run")
    }

    @Test func scheduleRestorePostsActionAndDecodesActiveSchedule() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/schedules/sch-1/restore")
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":3000}}
            """)
        }

        let schedule = try await client.restoreAgentSchedule("sch-1")

        #expect(schedule.status == .active)
        #expect(schedule.archivedAt == nil)
    }

    @Test func scheduleRunNowPostsRequestIdAndDecodesRun() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/schedules/sch-1/run")
            let body = try JSONDecoder().decode([String: String].self, from: requestBodyData(request))
            #expect(body["requestId"]?.hasPrefix("ios-manual-") == true)
            return mockResponse(status: 201, json: """
            {"run":{"id":"run-1","scheduleId":"sch-1","kind":"manual","slotKey":"manual:ios","idempotencyKey":"schedule:sch-1:manual:ios","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":2000,"sessionId":"sess-1","promptDispatch":"delivered"}}
            """)
        }

        let run = try await client.runAgentSchedule("sch-1")

        #expect(run.id == "run-1")
        #expect(run.sessionId == "sess-1")
        #expect(run.status == .completed)
    }

    @Test func controlSessionCreateUsesDeclaredMetadataAndPrompt() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/control-sessions")
            let body = try JSONDecoder().decode(APIClient.CreateControlSessionRequest.self, from: requestBodyData(request))
            #expect(body.domain == .agents)
            #expect(body.intent == .revise)
            #expect(body.targetId == "agent-1")
            #expect(body.targetName == "Reviewer")
            #expect(body.model == "anthropic/claude-opus-4-8")
            #expect(body.thinking == .high)
            #expect(body.prompt.contains("--definition-json"))
            return mockResponse(status: 201, json: """
            {"session":{"id":"control-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"revise","targetId":"agent-1","targetName":"Reviewer"}},"prompted":true}
            """)
        }

        let response = try await client.createControlSession(.init(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer",
            name: "Revise Reviewer",
            model: "anthropic/claude-opus-4-8",
            thinking: .high,
            prompt: ControlSessionStarterPrompt.make(
                domain: .agents,
                intent: .revise,
                targetId: "agent-1",
                targetName: "Reviewer"
            )
        ))

        #expect(response.session.control?.domain == .agents)
        #expect(response.session.workspaceId == nil)
        #expect(response.prompted == true)
    }

    @Test func focusedControlOperationsUseControlRouteFamily() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/control-sessions/control-1/trace-outline")
            return mockResponse(json: "{}")
        }
        _ = try? await client.getSessionTraceOutline(scope: .control, sessionId: "control-1")

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/control-sessions/control-1/events")
            #expect(request.url?.query == "since=9")
            return mockResponse(json: "{}")
        }
        _ = try? await client.getSessionEvents(scope: .control, id: "control-1", since: 9)

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/control-sessions/control-1/command")
            return mockResponse(json: "{}")
        }
        try await client.sendSessionCommand(
            scope: .control,
            sessionId: "control-1",
            message: .stop()
        )

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/control-sessions/control-1")
            return mockResponse(json: "{}")
        }
        try await client.deleteSession(scope: .control, sessionId: "control-1")
    }
}

@Suite("Agent icon presentation")
struct AgentIconPresentationTests {
    private func storedAgent(icon: String?, version: Int = 2) -> StoredAgentDefinition {
        StoredAgentDefinition(
            id: "agent-1",
            name: "Reviewer",
            icon: icon,
            description: nil,
            status: .active,
            version: version,
            definition: AgentDefinition(name: "Reviewer", icon: icon),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            archivedAt: nil
        )
    }

    @Test func classifiesTrimmedEmojiAndSymbolCandidatesDeterministically() {
        #expect(AgentIconValue.classify("  🧘  ") == .emoji("🧘"))
        #expect(AgentIconValue.classify(" checkmark.shield\n") == .symbolCandidate("checkmark.shield"))
        #expect(AgentIconValue.classify("🧘🧘") == .invalid(.multipleEmoji))
        #expect(AgentIconValue.classify(String(repeating: "a", count: 129)) == .invalid(.tooLong))
        #expect(AgentIconValue.classify("😀" + String(repeating: "‍😀", count: 64)) == .invalid(.tooLong))
        #expect(AgentIconValue.classify("not/a/symbol") == .invalid(.malformed))
    }

    @MainActor
    @Test func pickerPreviewsDraftAndSavesSuccessfulSelection() async {
        let model = AgentIconPickerModel(savedValue: "🧘")
        model.selectSuggestion("checkmark.shield")

        #expect(model.previewValue == "checkmark.shield")
        #expect(model.previewContent == .symbol("checkmark.shield"))

        let result = await model.saveCurrent { icon in
            #expect(icon == "checkmark.shield")
            return storedAgent(icon: icon, version: 3)
        }

        #expect(result?.version == 3)
        #expect(model.savedValue == "checkmark.shield")
        #expect(model.draft == "checkmark.shield")
        #expect(model.errorPresentation == nil)
    }

    @MainActor
    @Test func pickerClearUsesDefaultAndResetsPreview() async {
        let model = AgentIconPickerModel(savedValue: "checkmark.shield")

        let result = await model.useDefault { icon in
            #expect(icon == nil)
            return storedAgent(icon: nil, version: 3)
        }

        #expect(result?.definition.icon == nil)
        #expect(model.savedValue == nil)
        #expect(model.previewValue == nil)
        #expect(model.previewContent == .fallback)
        #expect(!model.canUseDefault)
    }

    @MainActor
    @Test func pickerShowsLiveValidationWithoutRequestingAccessibilityFocusDuringDraftEdits() {
        let model = AgentIconPickerModel(savedValue: "🧘")
        model.draft = "not-a-real-symbol"

        #expect(model.previewValue == "not-a-real-symbol")
        #expect(model.previewContent == .fallback)
        guard case .validation(let message) = model.errorPresentation else {
            Issue.record("Expected a validation error presentation")
            return
        }
        #expect(message.contains("isn’t available"))
        #expect(!model.canSave)
        #expect(model.accessibilityFocusRequest == nil)

        model.draft = "still-not-a-real-symbol"
        #expect(model.errorPresentation != nil)
        #expect(model.accessibilityFocusRequest == nil)
    }

    @MainActor
    @Test func pickerRequestsValidationFocusOnlyAfterExplicitSaveAttempt() async {
        let model = AgentIconPickerModel(savedValue: "🧘")
        model.draft = "not-a-real-symbol"

        let result = await model.saveCurrent { _ in
            Issue.record("Invalid drafts must not reach the save operation")
            return storedAgent(icon: nil)
        }

        #expect(result == nil)
        #expect(model.accessibilityFocusRequest?.target == .validation)
        #expect(model.accessibilityFocusRequest?.sequence == 1)

        model.draft = "still-not-a-real-symbol"
        #expect(model.accessibilityFocusRequest?.sequence == 1)
    }

    @MainActor
    @Test func pickerPreservesDraftAndExposesRetryAfterSaveFailure() async {
        struct SaveFailure: LocalizedError {
            var errorDescription: String? { "network unavailable" }
        }

        let model = AgentIconPickerModel(savedValue: "🧘")
        model.selectSuggestion("checkmark.shield")

        let failed = await model.saveCurrent { _ in
            throw SaveFailure()
        }

        #expect(failed == nil)
        #expect(model.draft == "checkmark.shield")
        #expect(model.errorMessage?.contains("network unavailable") == true)
        guard case .save(let message) = model.errorPresentation else {
            Issue.record("Expected a save error presentation")
            return
        }
        #expect(message.contains("network unavailable"))
        #expect(!model.isSaving)
        #expect(model.canSave)
        #expect(model.accessibilityFocusRequest?.target == .save)
        #expect(model.accessibilityFocusRequest?.sequence == 1)

        model.draft = "checkmark.shield "
        #expect(model.accessibilityFocusRequest?.sequence == 1)

        let retried = await model.saveCurrent { icon in
            storedAgent(icon: icon, version: 3)
        }
        #expect(retried?.version == 3)
        #expect(model.errorPresentation == nil)
    }

    @Test func scaledIconContentNeverExceedsItsLayoutBox() {
        let size = AgentIconSizingPolicy.contentSize(
            baseSize: 20,
            scaledSize: 40,
            frameSize: 24
        )

        #expect(size <= 24)
        #expect(size == 18.72)
    }

    @Test func ordinaryAndAgentSessionIdentityUseTheCorrectPresentation() {
        #expect(AssistantIdentityPresentation.resolve(agentId: nil, agentIcon: "🧘") == .globalAvatar)
        #expect(AssistantIdentityPresentation.resolve(agentId: "", agentIcon: "🧘") == .globalAvatar)
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: "🧘") == .agent(.text("🧘")))
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: "person.crop.circle") == .agent(.symbol("person.crop.circle")))
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: "not-a-real-symbol") == .agent(.fallback))
    }

    @Test func resolvesSupportedIconsAndFallbacks() {
        #expect(AgentIconContent.resolve("🧘") == .text("🧘"))
        #expect(AgentIconContent.resolve("👨‍👩‍👧‍👦") == .text("👨‍👩‍👧‍👦"))
        #expect(AgentIconContent.resolve("👋🏽") == .text("👋🏽"))
        #expect(AgentIconContent.resolve("🇺🇸") == .text("🇺🇸"))
        #expect(AgentIconContent.resolve("1️⃣") == .text("1️⃣"))
        #expect(AgentIconContent.resolve("person.crop.circle") == .symbol("person.crop.circle"))
        #expect(AgentIconContent.resolve(nil) == .fallback)
        #expect(AgentIconContent.resolve("   ") == .fallback)
        #expect(AgentIconContent.resolve("not-a-real-symbol") == .fallback)
        #expect(AgentIconContent.resolve("你好") == .fallback)
        #expect(AgentIconContent.resolve("é") == .fallback)
        #expect(AgentIconContent.resolve("1\u{0301}") == .fallback)
        #expect(AgentIconContent.resolve("1\u{FE0E}") == .fallback)
        #expect(AgentIconContent.resolve("1\u{0301}\u{FE0F}") == .fallback)
        #expect(AgentIconContent.resolve("©\u{20E3}") == .fallback)
        #expect(AgentIconContent.resolve("🧘\u{FE0E}") == .fallback)
        #expect(AgentIconContent.resolve("🧘\u{0301}") == .fallback)
        #expect(AgentIconContent.resolve("🧘\u{200D}") == .fallback)
        #expect(AgentIconContent.resolve("🧘\u{0301}\u{FE0F}") == .fallback)
        #expect(AgentIconContent.resolve("1\u{FE0F}\u{FE0F}\u{20E3}") == .fallback)
        #expect(AgentIconContent.resolve("😀🏽") == .fallback)
        #expect(AgentIconContent.resolve("🧘 Reviewer") == .fallback)
    }
}

@Suite("Schedule presentation")
struct SchedulePresentationTests {
    @Test func commonCronSchedulesUsePlainLanguage() {
        let daily = AgentScheduleTrigger.cron(expression: "0 8 * * *", timeZone: "America/Los_Angeles")
        let twiceDaily = AgentScheduleTrigger.cron(expression: "0 9,17 * * *", timeZone: "America/Los_Angeles")
        let weekly = AgentScheduleTrigger.cron(expression: "30 9 * * 1", timeZone: "America/Los_Angeles")

        #expect(daily.scheduleScreenCadence == "DAILY")
        #expect(daily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Every day · 8:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("9:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("5:00"))
        #expect(weekly.scheduleScreenCadence == "WEEKLY")
        #expect(weekly.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Mondays · 9:30"))
    }

    @Test func advancedSchedulesHideImplementationSyntax() {
        let custom = AgentScheduleTrigger.cron(expression: "0 8 1 * *", timeZone: "UTC")
        let interval = AgentScheduleTrigger.every(intervalMs: 7_200_000, timeZone: "UTC")

        #expect(custom.scheduleScreenCadence == "CUSTOM")
        #expect(custom.scheduleScreenTiming(locale: Locale(identifier: "en_US")) == "Custom schedule")
        #expect(interval.scheduleScreenCadence == "REPEATS")
        #expect(interval.scheduleScreenTiming(locale: Locale(identifier: "en_US")) == "Every 2h")
    }
}

@Suite("Control session starter prompts")
struct ControlSessionStarterPromptTests {
    @Test func scheduleCreationPromptCarriesRequestWorkspaceAndClarificationContract() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .create,
            workspaceId: "ws-7",
            workspaceName: "Dream",
            userRequest: "Brief me on coaching trends every Monday morning."
        )

        #expect(prompt.contains("User request:\nBrief me on coaching trends every Monday morning."))
        #expect(prompt.contains("Canonical workspace ID: ws-7"))
        #expect(prompt.contains("Canonical workspace name: Dream"))
        #expect(prompt.contains("`oppi schedule`"))
        #expect(prompt.contains("schedule behavior or timing is ambiguous"))
        #expect(prompt.contains("wait for explicit approval"))
    }

    @Test func agentCreationPromptTeachesTheAgentCommandAndBehaviorClarification() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .agents,
            intent: .create,
            workspaceId: "ws-2",
            workspaceName: "Oppi",
            userRequest: "Create a careful release reviewer."
        )

        #expect(prompt.contains("`oppi agent`"))
        #expect(prompt.contains("Agent behavior is ambiguous"))
        #expect(prompt.contains("Canonical workspace ID: ws-2"))
        #expect(prompt.contains("User request:\nCreate a careful release reviewer."))
    }

    @Test func revisionPromptIsDeterministicAndUsesCanonicalDefinitionInput() {
        let first = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .revise,
            targetId: "schedule-7",
            targetName: "Nightly review"
        )
        let second = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .revise,
            targetId: "schedule-7",
            targetName: "Nightly review"
        )

        #expect(first == second)
        #expect(first.contains("Canonical target ID: schedule-7"))
        #expect(first.contains("Canonical target name: Nightly review"))
        #expect(first.contains("--definition-json"))
        #expect(first.contains("Do not use filesystem tools or temporary files"))
        #expect(first.contains("wait for explicit approval"))
    }
}
