import Foundation
import os
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
        let navigation = SceneNavigation()
        let session = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.open(.chat(session))

        #expect(!navigation.isCoveringChat(sessionId: "session-1"))
        let reader = ChatReaderNavTarget(id: UUID())
        #expect(!navigation.containsChatReader(reader))

        navigation.open(.page(.chatReader(reader)))
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

    /// An incognito session ends when its chat leaves the route, so every
    /// remount of the same chat must keep the session in the route.
    @Test func sessionStaysInRouteAcrossReopenCoverAndShellSwapUntilPopped() {
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1", workspaceId: "workspace-1")))
        #expect(navigation.routeContainsSession("session-1"))
        #expect(!navigation.routeContainsSession("other-session"))

        // A notification or URL reopening the same session rebuilds its route.
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1", workspaceId: "workspace-1")), from: .external)
        #expect(navigation.routeContainsSession("session-1"))

        navigation.open(.page(.chatReader(ChatReaderNavTarget(id: UUID()))))
        #expect(navigation.routeContainsSession("session-1"))

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.routeContainsSession("session-1"))
        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.routeContainsSession("session-1"))

        navigation.popShownStack(toDepth: 0)
        #expect(!navigation.routeContainsSession("session-1"))
    }

    /// A sidebar pick or notification can replace a stack whose incognito chat
    /// is covered, without the chat ever appearing again: the route watch ends it.
    @Test func coveredIncognitoChatEndsWhenALaterRouteChangeDropsItsSession() async {
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "incognito", workspaceId: "workspace-1")))
        navigation.open(.page(.chatReader(ChatReaderNavTarget(id: UUID()))))
        let store = SessionStore()
        store.switchServer(to: "server-1")
        store.upsert(makeTestSession(id: "incognito"))
        let end = IncognitoSessionEnd(
            sessionId: "incognito", serverId: nil, scope: nil, apiClient: nil,
            sessionStore: store, navigation: navigation
        )
        end.endWhenRouteDrops(IncognitoRouteWatch())

        navigation.open(.page(.chatReader(ChatReaderNavTarget(id: UUID()))))
        await Self.settle()
        #expect(store.sessions.contains { $0.id == "incognito" }, "Another cover keeps the session")

        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "workspace-1")), from: .external)
        await Self.settle()
        #expect(!store.sessions.contains { $0.id == "incognito" }, "Replacing the stack ends the covered incognito session")
    }

    @Test func cancelledIncognitoRouteWatchKeepsTheSession() async {
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "incognito", workspaceId: "workspace-1")))
        let store = SessionStore()
        store.switchServer(to: "server-1")
        store.upsert(makeTestSession(id: "incognito"))
        let watch = IncognitoRouteWatch()
        IncognitoSessionEnd(
            sessionId: "incognito", serverId: nil, scope: nil, apiClient: nil,
            sessionStore: store, navigation: navigation
        ).endWhenRouteDrops(watch)
        // The chat showed again before the route changed.
        watch.cancel()

        navigation.popShownStack(toDepth: 0)
        await Self.settle()
        #expect(store.sessions.contains { $0.id == "incognito" })
    }

    /// An ended Incognito session is a deletion every window hears, so no
    /// pane keeps a route to it.
    @Test func anEndedIncognitoSessionIsPostedAsDeleted() async {
        let sessionId = "incognito-\(UUID().uuidString)"
        let navigation = SceneNavigation()
        let store = SessionStore()
        store.switchServer(to: "server-1")
        store.upsert(makeTestSession(id: sessionId))
        let posted = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
        let observer = NotificationCenter.default.addObserver(
            forName: ServerConnection.sessionDeletedNotification, object: nil, queue: nil
        ) { note in
            guard note.userInfo?["sessionId"] as? String == sessionId else { return }
            let info = note.userInfo as? [String: String]
            posted.withLock { $0 = info }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        IncognitoSessionEnd(
            sessionId: sessionId, serverId: "server-1", scope: nil, apiClient: nil,
            sessionStore: store, navigation: navigation
        ).forgetLocally()

        #expect(!store.sessions.contains { $0.id == sessionId })
        #expect(posted.withLock { $0 } == ["serverId": "server-1", "sessionId": sessionId])
    }

    private static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func containsChatReaderTracksStackedAndPoppedTargets() {
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")))
        let first = ChatReaderNavTarget(id: UUID())
        let second = ChatReaderNavTarget(id: UUID())

        navigation.open(.page(.chatReader(first)))
        #expect(navigation.containsChatReader(first))
        #expect(!navigation.containsChatReader(second))

        navigation.open(.page(.chatReader(second)))
        #expect(navigation.containsChatReader(first))
        #expect(navigation.containsChatReader(second))

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(!navigation.containsChatReader(second))
        #expect(navigation.containsChatReader(first))
    }

    @Test func nestedReaderOpenPushesOnTopOfTheExistingReader() {
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")))
        let first = ChatReaderNavTarget(id: UUID())
        navigation.open(.page(.chatReader(first)))
        let countAfterFirst = navigation.workspaceStackRouteElements.count

        let second = ChatReaderNavTarget(id: UUID())
        navigation.open(.page(.chatReader(second)))

        #expect(navigation.workspaceStackRouteElements.count == countAfterFirst + 1)
        #expect(navigation.containsChatReader(first))
        #expect(navigation.containsChatReader(second))
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
    }

    @Test func linkedFileOnTheSameSessionCoversChat() {
        let navigation = SceneNavigation()
        let session = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )
        navigation.open(.chat(session))
        navigation.open(.page(.linkedFile(.sessionFile(
                serverId: "server-1",
                workspaceId: "workspace-1",
                sessionId: "session-1",
                path: "README.md",
                sourceSessionId: "session-1"
            ))), from: .link)

        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
    }

    @Test func splitDetailReaderCoversTheRootSession() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        let session = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.open(.chat(session))
        let reader = ChatReaderNavTarget(id: UUID())
        navigation.open(.page(.chatReader(reader)))

        #expect(navigation.containsChatReader(reader))
        #expect(navigation.isCoveringChat(sessionId: "session-1"))
        #expect(!navigation.isCoveringChat(sessionId: "other-session"))
    }

    @Test func storingAReaderDropsPayloadsWhoseTargetIsNotOnTheStack() {
        let store = ChatReaderPayloadStore()
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")))

        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        navigation.open(.page(.chatReader(first)))
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))
        navigation.open(.page(.chatReader(second)))

        navigation.popShownStack(toDepth: 0)

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
        let navigation = SceneNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")))

        let first = store.store(ChatReaderPayload(content: .plainText(content: "one", filePath: "one.txt")))
        navigation.open(.page(.chatReader(first)))
        let second = store.store(ChatReaderPayload(content: .plainText(content: "two", filePath: "two.txt")))
        navigation.open(.page(.chatReader(second)))

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)

        let third = store.store(
            ChatReaderPayload(content: .plainText(content: "three", filePath: "three.txt")),
            retaining: navigation.containsChatReader
        )

        #expect(store.payload(for: first.id) != nil, "Still-stacked R1 must survive the next store")
        #expect(store.payload(for: second.id) == nil)
        #expect(store.payload(for: third.id) != nil)
    }
}
