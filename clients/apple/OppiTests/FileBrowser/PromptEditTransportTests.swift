import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

/// Own protocol class so this suite never races the shared `TestURLProtocol` handler.
private final class PromptEditURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((Recorded) throws -> (Int, Data))?
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Recorded(
            method: request.httpMethod ?? "",
            url: request.url!,
            body: request.httpBody ?? Self.readStream(request.httpBodyStream)
        )
        Self.lock.lock()
        Self.recorded.append(record)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(record)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    static var last: Recorded? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last
    }
}

/// An Agent's prompt and a Schedule's prompt are documents the editor opens; a
/// record's version is the tag a save conditions on, so a save that lost a race
/// reads as the editor's Conflict and one that finds the record gone as Deleted.
@Suite("Prompt edit transports", .serialized)
struct PromptEditTransportTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PromptEditURLProtocol.self]
        return APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: config
        )
    }

    private func json(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private func agent(
        version: Int = 2,
        instructions: AgentInstructions? = AgentInstructions(mode: .replace, text: "Review the diff.")
    ) -> StoredAgentDefinition {
        StoredAgentDefinition(
            id: "agent-1",
            name: "Reviewer",
            icon: .defaultValue,
            description: nil,
            status: .active,
            version: version,
            definition: AgentDefinition(name: "Reviewer", instructions: instructions),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func schedule(version: Int = 4, prompt: String = "Summarize yesterday.") -> AgentSchedule {
        AgentSchedule(
            id: "schedule-1",
            name: "Nightly",
            status: .active,
            trigger: .every(intervalMs: 3_600_000, timeZone: "UTC"),
            action: .newSession(
                workspaceId: "ws-1",
                prompt: prompt,
                agentId: nil,
                model: nil,
                thinkingLevel: nil,
                worktreeId: nil,
                name: nil
            ),
            version: version,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func agentTransport(_ client: APIClient, mode: AgentInstructionMode = .append) -> WorkspaceFileEditTransport {
        .agentInstructions(api: client, agentId: "agent-1", mode: { mode })
    }

    // MARK: Agent prompt

    @Test func agentPromptReadsItsTextAndVersion() async {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in (200, self.json(["agent": self.agent()])) }
        defer { PromptEditURLProtocol.reset() }

        let identity = WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1")
        let outcome = await agentTransport(client).read(identity)

        #expect(outcome == .snapshot(WorkspaceFileDiskSnapshot(
            bytes: Data("Review the diff.".utf8),
            etag: "2"
        )))
        #expect(PromptEditURLProtocol.last?.url.path == "/agents/agent-1")
    }

    /// An Agent with no custom prompt opens on an empty prompt, not on nothing.
    @Test func agentPromptWithNoCustomTextReadsEmpty() async {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in (200, self.json(["agent": self.agent(version: 7, instructions: nil)])) }
        defer { PromptEditURLProtocol.reset() }

        let outcome = await agentTransport(client).read(WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1"))

        #expect(outcome == .snapshot(WorkspaceFileDiskSnapshot(bytes: Data(), etag: "7")))
    }

    @Test func agentPromptSaveSendsTheVersionAndTheMode() async throws {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in (200, self.json(["agent": self.agent(version: 3)])) }
        defer { PromptEditURLProtocol.reset() }

        let identity = WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1")
        let outcome = await agentTransport(client, mode: .replace)
            .write(identity, Data("Review the branch.".utf8), "2")

        #expect(outcome == .saved(etag: "3"))
        let recorded = try #require(PromptEditURLProtocol.last)
        #expect(recorded.method == "PATCH")
        #expect(recorded.url.path == "/agents/agent-1")
        #expect(recorded.url.query == "expectedVersion=2")
        let body = try #require(
            try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any]
        )
        let instructions = try #require(body["instructions"] as? [String: Any])
        #expect(instructions["mode"] as? String == "replace")
        #expect(instructions["text"] as? String == "Review the branch.")
    }

    /// Emptying the prompt clears the custom one: the server refuses an empty
    /// text, and an explicit null is what removes it.
    @Test func agentPromptSaveWithNoTextClearsTheCustomPrompt() async throws {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in (200, self.json(["agent": self.agent(version: 3, instructions: nil)])) }
        defer { PromptEditURLProtocol.reset() }

        let identity = WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1")
        let outcome = await agentTransport(client).write(identity, Data(), "2")

        #expect(outcome == .saved(etag: "3"))
        let body = try #require(
            try JSONSerialization.jsonObject(with: (PromptEditURLProtocol.last?.body ?? Data())) as? [String: Any]
        )
        #expect(body["instructions"] is NSNull)
    }

    @Test func agentPromptSaveConflictsOnAStaleVersion() async {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in
            (409, Data(#"{"error":"Agent version conflict: expected 2, current 3","code":"AGENT_VERSION_CONFLICT","expectedVersion":2,"currentVersion":3}"#.utf8))
        }
        defer { PromptEditURLProtocol.reset() }

        let outcome = await agentTransport(client)
            .write(WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1"), Data("x".utf8), "2")

        #expect(outcome == .stale)
    }

    @Test func agentPromptOutcomesFollowTheRecord() async {
        let client = makeClient()
        defer { PromptEditURLProtocol.reset() }
        let identity = WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1")

        PromptEditURLProtocol.handler = { _ in (404, Data(#"{"error":"Agent not found"}"#.utf8)) }
        #expect(await agentTransport(client).read(identity) == .missing)
        #expect(await agentTransport(client).write(identity, Data("x".utf8), "2") == .missing)

        PromptEditURLProtocol.handler = { _ in (400, Data(#"{"error":"instructions.text must not be empty"}"#.utf8)) }
        if case .rejected(let status, let message) = await agentTransport(client).write(identity, Data("x".utf8), "2") {
            #expect(status == 400)
            #expect(message.contains("must not be empty"))
        } else {
            Issue.record("A refused save must read as rejected")
        }

        PromptEditURLProtocol.handler = { _ in (500, Data(#"{"error":"boom"}"#.utf8)) }
        #expect(await agentTransport(client).read(identity) == .failed)

        PromptEditURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        #expect(await agentTransport(client).write(identity, Data("x".utf8), "2") == .notSent)
    }

    // MARK: Schedule prompt

    @Test func schedulePromptReadsItsTextAndVersion() async {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in (200, self.json(["schedule": self.schedule()])) }
        defer { PromptEditURLProtocol.reset() }

        let outcome = await WorkspaceFileEditTransport
            .schedulePrompt(api: client, scheduleId: "schedule-1")
            .read(WorkspaceFileEditIdentity(serverId: "s1", scheduleId: "schedule-1"))

        #expect(outcome == .snapshot(WorkspaceFileDiskSnapshot(
            bytes: Data("Summarize yesterday.".utf8),
            etag: "4"
        )))
    }

    @Test func schedulePromptSaveSendsTheVersionAndThePrompt() async throws {
        let client = makeClient()
        let summary = AgentScheduleSummary(
            id: "schedule-1",
            name: "Nightly",
            status: .active,
            trigger: .every(intervalMs: 3_600_000, timeZone: "UTC"),
            action: AgentScheduleActionSummary(
                type: .newSession,
                workspaceId: "ws-1",
                sessionId: nil,
                agentId: nil,
                promptChars: 12
            ),
            version: 5,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            archivedAt: nil
        )
        PromptEditURLProtocol.handler = { _ in (200, self.json(["schedule": summary])) }
        defer { PromptEditURLProtocol.reset() }

        let transport = WorkspaceFileEditTransport.schedulePrompt(api: client, scheduleId: "schedule-1")
        let outcome = await transport.write(
            WorkspaceFileEditIdentity(serverId: "s1", scheduleId: "schedule-1"),
            Data("A newer prompt".utf8),
            "4"
        )

        #expect(outcome == .saved(etag: "5"))
        let recorded = try #require(PromptEditURLProtocol.last)
        #expect(recorded.url.query == "expectedVersion=4")
        let body = try #require(
            try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any]
        )
        let action = try #require(body["action"] as? [String: Any])
        #expect(action["prompt"] as? String == "A newer prompt")
    }

    @Test func schedulePromptSaveConflictsOnAStaleVersion() async {
        let client = makeClient()
        PromptEditURLProtocol.handler = { _ in
            (409, Data(#"{"error":"Schedule version conflict: expected 4, current 5","code":"SCHEDULE_VERSION_CONFLICT","expectedVersion":4,"currentVersion":5}"#.utf8))
        }
        defer { PromptEditURLProtocol.reset() }

        let outcome = await WorkspaceFileEditTransport.schedulePrompt(api: client, scheduleId: "schedule-1")
            .write(WorkspaceFileEditIdentity(serverId: "s1", scheduleId: "schedule-1"), Data("x".utf8), "4")

        #expect(outcome == .stale)
    }

    // MARK: The subject

    @Test func promptSubjectsCarryTheirRecordAndTheOwnerItsServer() {
        #expect(
            DocumentEditSubject.agentInstructions(agentId: "agent-1").editIdentity(serverId: "s1")
                == WorkspaceFileEditIdentity(serverId: "s1", agentId: "agent-1")
        )
        #expect(
            DocumentEditSubject.schedulePrompt(scheduleId: "schedule-1").editIdentity(serverId: "s1")
                == WorkspaceFileEditIdentity(serverId: "s1", scheduleId: "schedule-1")
        )
        // Without a server there is no document to write.
        #expect(DocumentEditSubject.agentInstructions(agentId: "agent-1").editIdentity(serverId: nil) == nil)
        #expect(DocumentEditSubject.snapshot.editIdentity(serverId: "s1") == nil)
        // Both prompts are Markdown, as their readers show them.
        #expect(DocumentEditSubject.agentInstructions(agentId: "a").fileType == .markdown)
        #expect(DocumentEditSubject.schedulePrompt(scheduleId: "s").fileType == .markdown)
    }
}
