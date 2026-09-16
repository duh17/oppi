import Foundation
import Testing
@testable import Oppi

@Suite("Chat covered lifetime")
@MainActor
struct ChatCoveredLifetimeTests {
    @Test func payloadStoreRetainsStackedReadersWhenASecondPayloadIsStored() {
        let store = ChatReaderPayloadStore()
        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))

        #expect(store.payload(for: first.id) != nil, "Opening a nested reader must not wipe the still-stacked payload")
        #expect(store.payload(for: second.id) != nil)
        #expect(first.id != second.id)
    }

    @Test func timelineReaderOpenDoesNotSwallowOrWipeWhenAReaderIsAlreadyShowing() {
        let whileCovered = ChatView.timelineReaderOpenPlan(isShowingChatReader: true)
        #expect(whileCovered.shouldOpen, "Nested reader open must not be swallowed because a reader is already showing")
        #expect(!whileCovered.shouldWipePayloadStore, "Payload store must not globally wipe still-stacked readers")
        #expect(whileCovered.shouldPreflight, "Reader open must preflight like wiki before push")

        let firstOpen = ChatView.timelineReaderOpenPlan(isShowingChatReader: false)
        #expect(firstOpen.shouldOpen)
        #expect(!firstOpen.shouldWipePayloadStore)
        #expect(firstOpen.shouldPreflight)
    }

    @Test func stackedReaderDoesNotCountAsRemovedChat() {
        let navigation = AppNavigation()
        let session = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.openWorkspaceSession(session)

        #expect(!navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isShowingChatReader())

        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))
        #expect(navigation.isShowingChatReader())
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
        #expect(!ChatView.shouldTeardownOnDisappear(isCovered: true))
        #expect(ChatView.shouldTeardownOnDisappear(isCovered: false))
    }

    @Test func nestedReaderOpenPushesOnTopOfTheExistingReader() {
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )
        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))
        let countAfterFirst = navigation.workspacePath.count

        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))

        #expect(navigation.workspacePath.count == countAfterFirst + 1)
        #expect(navigation.isShowingChatReader())
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
    }

    @Test func linkedFileOnTheSameSessionCoversChat() {
        let navigation = AppNavigation()
        let session = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )
        navigation.openWorkspaceSession(session)
        navigation.openReferencedWorkspaceLinkedFile(
            .sessionFile(
                serverId: "server-1",
                workspaceId: "workspace-1",
                sessionId: "session-1",
                path: "README.md",
                sourceSessionId: "session-1"
            ),
            sourceSession: session
        )

        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
    }

    @Test func splitDetailReaderCoversTheRootSession() {
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        let session = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.openWorkspaceSession(session)
        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))

        #expect(navigation.isShowingChatReader())
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
    }
}
