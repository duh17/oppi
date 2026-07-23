import Testing
@testable import Oppi

@Suite("Reviewable control Markdown")
@MainActor
struct ReviewableControlMarkdownTests {
    private enum RetryFailure: Error {
        case simulatedNetworkFailure
    }
    @Test func targetDraftKeysAreSeparatedByServerDomainAndCanonicalTarget() {
        let firstServer = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .schedules,
            targetId: "shared-id"
        )
        let secondServer = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-2",
            fallbackServerId: nil,
            domain: .schedules,
            targetId: "shared-id"
        )
        let agent = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .agents,
            targetId: "shared-id"
        )
        let skill = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "shared-id"
        )

        #expect(firstServer == "server-1:schedules:shared-id")
        #expect(firstServer != secondServer)
        #expect(firstServer != agent)
        #expect(skill == "server-1:skills:shared-id")
    }

    @Test func targetDraftKeyUsesActiveServerFallback() {
        #expect(
            ReviewableControlMarkdownDraftKey.make(
                serverId: nil,
                fallbackServerId: "cached-server",
                domain: .agents,
                targetId: "agent-1"
            ) == "cached-server:agents:agent-1"
        )
    }

    @Test func promptedFalseRetryReusesCreatedSessionAndStableRequestId() async throws {
        let session = makeTestSession(id: "control-session-1")
        let requestId = "stable-request-id"
        var createCalls = 0
        var cachedSessions: [Session] = []
        var sentRequestIds: [String] = []
        var retainedSession: Session?
        var delivered = false

        do {
            _ = try await ControlRevisionSessionLaunchCoordinator.prepare(
                existingSession: retainedSession,
                starterPromptDelivered: delivered,
                requestId: requestId,
                create: {
                    createCalls += 1
                    return (session, false)
                },
                onSessionCreated: { created, promptDelivered in
                    retainedSession = created
                    delivered = promptDelivered
                    cachedSessions.append(created)
                },
                sendStarterPrompt: { _, sentRequestId in
                    sentRequestIds.append(sentRequestId)
                    throw RetryFailure.simulatedNetworkFailure
                }
            )
            Issue.record("The first starter-prompt delivery should fail")
        } catch RetryFailure.simulatedNetworkFailure {
        }

        let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: retainedSession,
            starterPromptDelivered: delivered,
            requestId: requestId,
            create: {
                createCalls += 1
                return (session, false)
            },
            onSessionCreated: { _, _ in
                Issue.record("Retry must reuse the retained session")
            },
            sendStarterPrompt: { retriedSession, sentRequestId in
                #expect(retriedSession.id == session.id)
                sentRequestIds.append(sentRequestId)
            }
        )

        #expect(createCalls == 1)
        #expect(cachedSessions.map(\.id) == [session.id])
        #expect(sentRequestIds == [requestId, requestId])
        #expect(prepared.session.id == session.id)
        #expect(prepared.starterPromptDelivered)
    }
}
