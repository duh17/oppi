import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session stop and resume")
struct MacSessionTraceStoreStopTests {
    @Test func stopTurnSendsClientMessageStopNotStopSession() async {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let sent = SentMessageBox()
        store._sendLiveMessageForTesting = { message in
            sent.message = message
            return true
        }

        await store.stopTurn(target: target, client: unusedClient)

        switch sent.message {
        case .stop:
            break
        case .stopSession:
            Issue.record("Composer stop must not send stopSession")
        default:
            Issue.record("Expected ClientMessage.stop, got \(String(describing: sent.message))")
        }
        #expect(!store.isStoppingTurn)
    }

    @Test func resumeStoppedSessionUsesRESTAndRestoresTheComposer() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .stopped)
        store.select(target)

        var resumed = target.summary.session
        resumed.status = .ready
        let responseData = try JSONEncoder().encode(SessionResponseFixture(session: resumed))
        let transport = RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: responseData
        ))
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-resume.sock",
            token: "test",
            transport: transport
        )

        await store.resumeSession(target: target, client: client)

        #expect(store.session?.status == .ready)
        #expect(store.resumeError == nil)
        #expect(!store.isResumingSession)
        let request = await transport.requests.first
        #expect(request?.method == "POST")
        #expect(request?.path == "/workspaces/workspace-stop/sessions/session-stop/resume")
    }

    @Test func resumeFailureStaysStoppedAndSurfacesAnActionableError() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .stopped)
        store.select(target)

        let transport = RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
            statusCode: 503,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"Server is restarting"}"#.utf8)
        ))
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-resume-failure.sock",
            token: "test",
            transport: transport
        )

        await store.resumeSession(target: target, client: client)

        #expect(store.session?.status == .stopped)
        #expect(store.lastError == nil)
        #expect(store.resumeError?.contains("Resume failed") == true)
        #expect(store.resumeError?.contains("Server is restarting") == true)
        #expect(
            MacTimelineFailurePaint.message(
                status: store.session?.status,
                lastError: store.lastError
            ) == nil
        )
        #expect(!store.isResumingSession)
    }

    @Test func resumeFailurePreservesARealTimelineLoadError() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .stopped)
        let loadTransport = RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
            statusCode: 503,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"Trace store unavailable"}"#.utf8)
        ))
        let loadClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-load-failure.sock",
            token: "test",
            transport: loadTransport
        )
        defer { store.clearSelection() }

        await store.load(target: target, client: loadClient)
        let timelineError = store.lastError
        #expect(timelineError?.contains("Failed to load session history") == true)

        let resumeTransport = RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
            statusCode: 503,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"Server is restarting"}"#.utf8)
        ))
        let resumeClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-resume-failure.sock",
            token: "test",
            transport: resumeTransport
        )

        await store.resumeSession(target: target, client: resumeClient)

        #expect(store.lastError == timelineError)
        #expect(store.resumeError?.contains("Server is restarting") == true)
        #expect(
            MacTimelineFailurePaint.message(
                status: store.session?.status,
                lastError: store.lastError
            ) == timelineError
        )
    }

    private let unusedClient = MacWorkspaceClient(
        socketPath: "/tmp/oppi-mac-unused.sock",
        token: "test"
    )

    private func makeTarget(status: SessionStatus = .busy) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "session-stop",
            workspaceId: "workspace-stop",
            workspaceName: "Workspace",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello",
            runtime: .oppi
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-stop",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

private struct SessionResponseFixture: Encodable {
    let session: Session
}

@MainActor
private final class SentMessageBox {
    var message: ClientMessage?
}
