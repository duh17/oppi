import Testing
import UIKit
@testable import Oppi

/// A Live Voice call belongs to the app, not to the chat that shows it: leaving the chat
/// keeps the call running, and the session's next chat shows the same call.
@Suite("Live Voice call lifetime")
@MainActor
struct LiveVoiceCallLifetimeTests {
    private let serverId = "sha256:live-voice-lifetime"
    private let workspaceId = "ws-1"

    @Test("Leaving the chat keeps the call: no detach or end, and the session's next chat shows and ends the same call")
    func callOutlivesItsChat() async throws {
        let fixture = try await Fixture(serverId: serverId, workspaceId: workspaceId)
        defer { fixture.remove() }
        let sessionId = fixture.sessionId
        let call = try await fixture.startConfirmedCall()

        let first = fixture.mountChat()
        #expect(await waitForMainActorCondition { fixture.endButton(in: first.chat) != nil },
                "The chat on the session shows the call")

        // Back to the list: the chat leaves the window and is released.
        first.unmount()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.channel.sent.contains { ["voice_call_detach", "voice_call_end"].contains($0.typeLabel) },
                "Leaving the chat sent \(fixture.channel.sent.map(\.typeLabel))")
        #expect(!fixture.channel.closed)
        #expect(call.isLive)
        #expect(fixture.root.liveVoiceCalls.call(serverId: serverId, sessionId: sessionId) === call)

        // Another session's chat: the call still owns the one microphone.
        let other = fixture.mountChat(sessionId: "other-\(UUID().uuidString)")
        #expect(other.chat.liveVoiceCallOwnsMic)
        #expect(other.chat.liveVoiceCall == nil)
        #expect(fixture.endButton(in: other.chat) == nil, "Another session's composer shows no call")
        other.unmount()

        // Reopening the session shows the same call; its End ends it on the call's own stream.
        let reopened = fixture.mountChat()
        defer { reopened.unmount() }
        let end = try #require(await fixture.waitForEndButton(in: reopened.chat))
        end.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition { fixture.channel.sent.last?.typeLabel == "voice_call_end" })
        #expect(await waitForMainActorCondition { !call.isLive })
        #expect(fixture.root.liveVoiceCalls.currentCall == nil)
        #expect(!reopened.chat.liveVoiceCallOwnsMic)
    }

    @Test("A chat that opens mid-call keeps the pre-call draft aside, and the draft returns once when the call ends")
    func chatOpeningMidCallKeepsTheDraftAside() async throws {
        let fixture = try await Fixture(serverId: serverId, workspaceId: workspaceId)
        defer { fixture.remove() }
        fixture.drafts.setDraft(ComposerDraftPayload(text: "draft before the call", repoPointers: []), for: fixture.draftKey)
        let call = try await fixture.startConfirmedCall()

        let chat = fixture.mountChat()
        defer { chat.unmount() }
        #expect(await waitForMainActorCondition { fixture.endButton(in: chat.chat) != nil })
        #expect(chat.chat.composerDraftController.text.isEmpty, "The call's composer starts empty")
        #expect(fixture.drafts.record(for: fixture.draftKey)?.payload.text == "draft before the call",
                "The stored draft stays put while the call runs")

        await call.end()
        #expect(await waitForMainActorCondition {
            chat.chat.composerDraftController.text == "draft before the call"
        }, "Got \(chat.chat.composerDraftController.text.debugDescription)")
        #expect(fixture.drafts.record(for: fixture.draftKey)?.payload.text == "draft before the call")
    }

    @Test("A call that ends while its chat is gone leaves the pre-call draft for the next chat, once")
    func callEndingWhileUnmountedLeavesTheDraft() async throws {
        let fixture = try await Fixture(serverId: serverId, workspaceId: workspaceId)
        defer { fixture.remove() }
        fixture.drafts.setDraft(ComposerDraftPayload(text: "draft before the call", repoPointers: []), for: fixture.draftKey)
        let call = try await fixture.startConfirmedCall()

        let during = fixture.mountChat()
        #expect(await waitForMainActorCondition { fixture.endButton(in: during.chat) != nil })
        #expect(during.chat.composerDraftController.text.isEmpty)
        during.unmount()
        await call.end()

        let after = fixture.mountChat()
        defer { after.unmount() }
        #expect(await waitForMainActorCondition {
            after.chat.composerDraftController.text == "draft before the call"
        }, "Got \(after.chat.composerDraftController.text.debugDescription)")
        #expect(fixture.endButton(in: after.chat) == nil)
    }
}

/// One server, one session, and the app root whose call center makes calls on a fake channel.
@MainActor
private struct Fixture {
    let sessionId = "session-\(UUID().uuidString)"
    let connection: ServerConnection
    let channel = FakeLiveVoiceCallChannel()
    let drafts: ComposerDraftStore
    let draftsURL: URL
    let root: AppRootEnvironment
    let draftKey: ComposerDraftKey
    let workspaceId: String

    init(serverId: String, workspaceId: String) async throws {
        self.workspaceId = workspaceId
        connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials(fingerprint: serverId))
        connection.sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId))
        draftsURL = FileManager.default.temporaryDirectory
            .appending(path: "live-voice-lifetime-\(UUID().uuidString).json", directoryHint: .notDirectory)
        drafts = ComposerDraftStore(fileURL: draftsURL, saveDelay: .seconds(60))
        await drafts.load()
        let channel = channel
        root = makeTestAppRoot(
            composerDraftStore: drafts,
            liveVoiceCalls: LiveVoiceCallCenter {
                LiveVoiceCallController(
                    channel: channel,
                    audio: FakeLiveVoiceAudioOwner(),
                    memory: FakeLiveVoiceSessionMemory()
                )
            }
        )
        draftKey = try #require(ComposerDraftKey(serverID: serverId, workspaceID: workspaceId, sessionID: sessionId))
    }

    func remove() {
        try? FileManager.default.removeItem(at: draftsURL)
    }

    /// A call on the session, placed with the app's center and confirmed by the server.
    func startConfirmedCall() async throws -> LiveVoiceCallController {
        let serverId = try #require(connection.currentServerId)
        let call = try #require(root.liveVoiceCalls.placeCall(serverId: serverId, sessionId: sessionId))
        let start = Task { await call.start(sessionId: sessionId, routeScope: .workspace(workspaceId)) }
        #expect(await waitForMainActorCondition { !channel.opened.isEmpty })
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        #expect(await waitForMainActorCondition { channel.sent.map(\.typeLabel) == ["voice_call_start"] })
        channel.emit(.voiceCallState(VoiceCallStateSnapshot(
            callId: "call-1",
            controlSessionId: sessionId,
            lifecycle: .active,
            frontend: .attached,
            controllerLeaseEpoch: 1,
            controllerLeaseExpiresAt: 30_000,
            eventSeq: 1,
            startedAt: 1_000,
            updatedAt: 2_000,
            delegations: [],
            partialTranscript: nil
        )))
        await start.value
        try #require(call.isLive)
        return call
    }

    func mountChat(sessionId: String? = nil) -> MountedChat {
        let chat = ChatViewController(
            sessionId: sessionId ?? self.sessionId,
            connection: connection,
            navigation: root.navigation,
            workspaceIdHint: workspaceId
        )
        chat.sessionManager._loadHistoryForTesting = { _, _ in nil }
        let window = makeSceneWindow()
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = chat
        window.makeKeyAndVisible()
        chat.view.layoutIfNeeded()
        return MountedChat(chat: chat, window: window)
    }

    func endButton(in chat: ChatViewController) -> UIControl? {
        timelineAllViews(in: chat.view).first {
            $0.accessibilityIdentifier == ComposerLiveVoiceCall.endIdentifier && !$0.isHidden && $0.window != nil
        } as? UIControl
    }

    func waitForEndButton(in chat: ChatViewController) async -> UIControl? {
        _ = await waitForMainActorCondition { endButton(in: chat) != nil }
        return endButton(in: chat)
    }
}

@MainActor
private struct MountedChat {
    let chat: ChatViewController
    let window: UIWindow

    /// Takes the chat out of the window, as a pop back to the list does.
    func unmount() {
        window.rootViewController = UIViewController()
        window.layoutIfNeeded()
        window.isHidden = true
        chat.sessionManager.cleanup()
    }
}
