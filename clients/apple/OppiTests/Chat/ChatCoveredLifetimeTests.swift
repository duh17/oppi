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
        let reader = ChatReaderNavTarget(id: UUID())
        #expect(!navigation.containsChatReader(reader))

        navigation.openChatReader(reader)
        #expect(navigation.containsChatReader(reader))
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
        let first = ChatReaderNavTarget(id: UUID())
        navigation.openChatReader(first)
        let countAfterFirst = navigation.workspacePath.count

        let second = ChatReaderNavTarget(id: UUID())
        navigation.openChatReader(second)

        #expect(navigation.workspacePath.count == countAfterFirst + 1)
        #expect(navigation.containsChatReader(first))
        #expect(navigation.containsChatReader(second))
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
        let reader = ChatReaderNavTarget(id: UUID())
        navigation.openChatReader(reader)

        #expect(navigation.containsChatReader(reader))
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
    }

    @Test func storingAReaderDropsPayloadsWhoseTargetIsNotOnTheStack() {
        let store = ChatReaderPayloadStore()
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )

        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        navigation.openChatReader(first)
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))
        navigation.openChatReader(second)

        navigation.workspacePath.removeLast(navigation.workspacePath.count)

        let third = store.store(
            ChatReaderPayload(content: .plainText(content: "three", filePath: "three.txt")),
            retaining: navigation.containsChatReader
        )

        #expect(store.payload(for: first.id) == nil, "Pop-to-root must drop covered R1 even without onDisappear")
        #expect(store.payload(for: second.id) == nil)
        #expect(store.payload(for: third.id) != nil)
    }

    @Test func storingAReaderKeepsPayloadsStillOnTheStack() {
        let store = ChatReaderPayloadStore()
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )

        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        navigation.openChatReader(first)
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))
        navigation.openChatReader(second)

        navigation.workspacePath.removeLast()

        let third = store.store(
            ChatReaderPayload(content: .plainText(content: "three", filePath: "three.txt")),
            retaining: navigation.containsChatReader
        )

        #expect(store.payload(for: first.id) != nil, "Still-stacked R1 must survive the next store")
        #expect(store.payload(for: second.id) == nil)
        #expect(store.payload(for: third.id) != nil)
    }
}
