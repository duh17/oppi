import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("ChatView Lifecycle")
@MainActor
struct ChatViewLifecycleTests {
    @Test func onAppearPreparesSessionReentryBeforeAsyncConnectLoop() async {
        let parentId = "parent-\(UUID().uuidString)"
        let childId = "child-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: childId)
        let appNavigation = AppNavigation()
        let piQuickActionStore = PiQuickActionStore(actions: [])

        connection.sessionStore.upsert(makeTestSession(id: parentId, status: .ready))

        // Simulate the child session having been torn down during navigation.
        connection.disconnectSession()
        connection.wsClient?._setStatusForTesting(.disconnected)
        connection.streamConsumptionTask = nil

        #expect(connection.focusedSessionId == nil)

        var preparedSessionIds: [String] = []
        connection._onPrepareForSessionReentryForTesting = { sessionId in
            preparedSessionIds.append(sessionId)
        }

        let root = AnyView(
            ChatView(sessionId: parentId)
                .environment(connection)
                .environment(connection.chatState)
                .environment(connection.sessionStore)
                .environment(connection.audioPlayer)
                .environment(connection.gitStatusStore)
                .environment(connection.fileIndexStore)
                .environment(connection.messageQueueStore)
                .environment(connection.permissionStore)
                .environment(appNavigation)
                .environment(piQuickActionStore)
        )

        let controller = UIHostingController(rootView: root)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let prepared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { preparedSessionIds == [parentId] }
        }

        #expect(prepared, "Expected ChatView.onAppear to prepare session re-entry for the parent session")
        #expect(connection.focusedSessionId == parentId)

        controller.rootView = AnyView(EmptyView())
        window.isHidden = true
        window.rootViewController = nil
        connection.disconnectSession()
        connection.disconnectStream()
    }
}
