import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Edit Schedule draft")
struct ScheduleEditDraftTests {
    private static let trigger = AgentScheduleTrigger.every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles")

    private func schedule(action: AgentScheduleAction, trigger: AgentScheduleTrigger = Self.trigger) -> AgentSchedule {
        AgentSchedule(
            id: "schedule-1",
            name: "Nightly digest",
            status: .active,
            trigger: trigger,
            action: action,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func newSession(workspaceId: String = "ws-1") -> AgentScheduleAction {
        .newSession(
            workspaceId: workspaceId, prompt: "Summarize the day.", agentId: nil, model: nil,
            thinkingLevel: nil, worktreeId: "wt-1", name: nil
        )
    }

    private func draft(
        _ schedule: AgentSchedule,
        connection: ServerConnection = ServerConnection()
    ) -> ScheduleEditDraft {
        ScheduleEditDraft(schedule: schedule, connection: connection, serverName: "mac-studio")
    }

    @Test("Save needs a name, a prompt, a workspace, and a trigger that validates")
    func canSaveRules() {
        let draft = draft(schedule(action: newSession()))
        #expect(draft.canSave)

        draft.name = "   "
        #expect(!draft.canSave, "a blank name")
        draft.name = "Nightly digest"

        draft.prompt = "\n"
        #expect(!draft.canSave, "a blank prompt")
        draft.prompt = "Summarize the day."

        draft.triggerDraft.cadence = .custom
        draft.triggerDraft.customExpression = "61 * * * *"
        #expect(!draft.canSave, "a cron expression the server would refuse")
        draft.triggerDraft.customExpression = "0 9 * * 1-5"
        #expect(draft.canSave)
    }

    @Test("an existing-session schedule also needs its target session")
    func existingSessionNeedsATarget() {
        let existing = schedule(action: .existingSession(
            workspaceId: "ws-1", sessionId: "s-1", prompt: "Check in.", streamingBehavior: nil
        ))
        let draft = draft(existing)
        #expect(draft.canSave)
        draft.targetSessionId = ""
        #expect(!draft.canSave)
    }

    @Test("changing the workspace moves an existing-session schedule off a session of the old one")
    func selectingAWorkspaceRetargetsTheSession() {
        let connection = ServerConnection()
        let existing = schedule(action: .existingSession(
            workspaceId: "ws-1", sessionId: "s-1", prompt: "Check in.", streamingBehavior: nil
        ))
        let draft = draft(existing, connection: connection)
        // The new workspace has no session, so the target is cleared and Save waits for a choice.
        draft.selectWorkspace("ws-2")
        #expect(draft.workspaceId == "ws-2")
        #expect(draft.targetSessionId.isEmpty)
        #expect(!draft.canSave)

        // A new-session schedule has no target to move.
        let fresh = self.draft(schedule(action: newSession()), connection: connection)
        fresh.selectWorkspace("ws-2")
        #expect(fresh.workspaceId == "ws-2")
        #expect(fresh.targetSessionId.isEmpty)
        #expect(fresh.canSave)
    }

    @Test("the repeat intervals offered always include the schedule's own")
    func intervalOptionsIncludeTheCurrentInterval() {
        let odd = schedule(
            action: newSession(),
            trigger: .every(intervalMs: 7 * 60_000, timeZone: "UTC")
        )
        let draft = draft(odd)
        #expect(draft.intervalOptions.contains(7 * 60_000))
        #expect(draft.intervalOptions == draft.intervalOptions.sorted())
        #expect(draft.intervalOptions.contains(15 * 60_000))
    }

    @Test("Save sends the edited schedule and returns it with the server's answer")
    func saveSendsTheEditsAndReturnsTheSchedule() async throws {
        let host = "schedule-save-\(UUID().uuidString)"
        let sent = SentRequests()
        ScheduleSaveStub.register(host: host) { request in
            await sent.record(request)
            return """
            {"schedule":{"id":"schedule-1","name":"Weekday digest","status":"active","trigger":{"type":"every","intervalMs":3600000,"timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":7},"createdAt":1000,"updatedAt":2000}}
            """
        }
        defer { ScheduleSaveStub.unregister(host: host) }
        let draft = draft(schedule(action: newSession()))
        draft.name = "Weekday digest"
        draft.prompt = "Digest."
        draft.agentId = "agent-9"
        draft.model = "  "
        draft.thinkingLevel = .high
        draft.sessionName = " Digest run "

        let saved = try #require(await draft.save(apiClient: ScheduleSaveStub.client(host: host)))
        #expect(saved.schedule.name == "Weekday digest")
        #expect(saved.schedule.updatedAt == saved.summary.updatedAt)
        guard case .newSession(let workspaceId, let prompt, let agentId, let model, let thinking, let worktreeId, let name) = saved.schedule.action else {
            Issue.record("Expected a new-session action")
            return
        }
        #expect(workspaceId == "ws-1")
        #expect(prompt == "Digest.")
        #expect(agentId == "agent-9")
        #expect(model == nil, "a blank model clears the override")
        #expect(thinking == .high)
        #expect(worktreeId == "wt-1", "the worktree the editor does not show is kept")
        #expect(name == "Digest run")

        let request = try #require(await sent.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/schedules/schedule-1")
        #expect(!draft.isSaving)
    }

    @Test("a failed Save keeps the draft and says why")
    func failedSaveKeepsTheDraft() async throws {
        let host = "schedule-fail-\(UUID().uuidString)"
        ScheduleSaveStub.register(host: host, status: 500) { _ in #"{"error":"The server could not save."}"# }
        defer { ScheduleSaveStub.unregister(host: host) }
        let draft = draft(schedule(action: newSession()))
        draft.name = "Renamed"

        let saved = await draft.save(apiClient: ScheduleSaveStub.client(host: host))
        #expect(saved == nil)
        #expect(draft.error != nil)
        #expect(draft.name == "Renamed")
        #expect(draft.canSave, "the person can fix it and try again")

        let offline = await draft.save(apiClient: nil)
        #expect(offline == nil)
        #expect(draft.error == "Server is offline")
    }

    @Test("a calendar event's draft creates a one-time session schedule at the offset chosen")
    func eventDraftCreatesAOneTimeSchedule() async throws {
        let host = "schedule-event-\(UUID().uuidString)"
        let sent = SentRequests()
        ScheduleSaveStub.register(host: host) { request in
            await sent.record(request)
            return """
            {"schedule":{"id":"new-1","name":"Design review","status":"active","trigger":{"type":"at","at":1,"timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":7},"createdAt":1000,"updatedAt":1000}}
            """
        }
        defer { ScheduleSaveStub.unregister(host: host) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let start = Date().addingTimeInterval(3 * 3_600).rounded(toMinutes: 1)
        let event = ScheduleCalendarEvent(
            id: "review", title: "Design review", start: start, end: start.addingTimeInterval(2_700),
            isAllDay: false, location: "Zoom", notes: nil, calendarTitle: "Work"
        )
        let draft = ScheduleEditDraft(event: event, connection: ServerConnection(), serverName: "mac-studio", calendar: calendar)
        #expect(draft.name == "Design review")
        #expect(draft.triggerDraft.cadence == .oneTime)
        #expect(draft.triggerDraft.timeZone == "America/Los_Angeles")
        #expect(draft.eventOffset == .minutesBefore(30))
        #expect(draft.prompt.contains("Location: Zoom"))
        #expect(!draft.canSave, "no workspace yet")
        draft.workspaceId = "ws-1"
        #expect(draft.canSave)

        draft.chooseEventOffset(.minutesBefore(15))
        #expect(draft.triggerDraft.oneTimeDate == start.addingTimeInterval(-900))
        draft.triggerDraft.oneTimeDate = start.addingTimeInterval(-7)
        #expect(draft.eventOffset == nil, "a time set by hand matches no offset")
        draft.triggerDraft.oneTimeDate = Date().addingTimeInterval(-60)
        #expect(!draft.canSave, "a time already past would never run")
        draft.chooseEventOffset(.minutesBefore(15))

        let saved = try #require(await draft.save(apiClient: ScheduleSaveStub.client(host: host)))
        #expect(saved.schedule.id == "new-1")
        let request = try #require(await sent.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/schedules")
        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        })
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let trigger = try #require(json["trigger"] as? [String: Any])
        #expect(trigger["type"] as? String == "at")
        #expect((trigger["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } == start.addingTimeInterval(-900))
        let action = try #require(json["action"] as? [String: Any])
        #expect(action["type"] as? String == "new_session")
        #expect(action["workspaceId"] as? String == "ws-1")
        #expect((action["prompt"] as? String)?.contains("<calendar_event>") == true)
    }
}

private extension Date {
    /// Down to a whole number of minutes, so a time survives the trip through milliseconds.
    func rounded(toMinutes minutes: Int) -> Date {
        let step = TimeInterval(minutes * 60)
        return Date(timeIntervalSince1970: (timeIntervalSince1970 / step).rounded(.down) * step)
    }
}

private actor SentRequests {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) { requests.append(request) }
}

/// Answers a schedule PATCH for the host a test registered.
private final class ScheduleSaveStub: URLProtocol, @unchecked Sendable {
    private struct Route {
        let status: Int
        let body: @Sendable (URLRequest) async -> String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    static func register(host: String, status: Int = 200, body: @escaping @Sendable (URLRequest) async -> String) {
        lock.withLock { routes[host] = Route(status: status, body: body) }
    }

    static func unregister(host: String) {
        lock.withLock { routes[host] = nil }
    }

    @MainActor
    static func client(host: String) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduleSaveStub.self]
        return APIClient(
            baseURL: URL(string: "http://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "sk_test",
            configuration: configuration
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let route = request.url?.host.flatMap { host in Self.lock.withLock { Self.routes[host] } }
        Task {
            guard let route, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let body = await route.body(request)
            let response = HTTPURLResponse(
                url: url, statusCode: route.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
