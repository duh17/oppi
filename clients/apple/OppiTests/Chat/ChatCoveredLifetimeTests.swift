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
    }

    @Test func poppingAReaderRemovesOnlyThatPayload() {
        let store = ChatReaderPayloadStore()
        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))

        store.remove(first)

        #expect(store.payload(for: first.id) == nil)
        #expect(store.payload(for: second.id) != nil)
    }

    @Test func containsChatReaderTracksStackedAndPoppedTargets() {
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )
        let first = ChatReaderNavTarget(id: UUID())
        let second = ChatReaderNavTarget(id: UUID())

        navigation.openChatReader(first)
        #expect(navigation.containsChatReader(first))
        #expect(!navigation.containsChatReader(second))

        navigation.openChatReader(second)
        #expect(navigation.containsChatReader(first))
        #expect(navigation.containsChatReader(second))

        navigation.workspacePath.removeLast()
        #expect(!navigation.containsChatReader(second))
        #expect(navigation.containsChatReader(first))
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
