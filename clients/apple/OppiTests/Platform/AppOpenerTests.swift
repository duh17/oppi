import CryptoKit
import Foundation
import LocalAuthentication
import os
import Testing
@testable import Oppi

/// Every entry point delivers one `AppOpenRequest` to one owner. These tests
/// drive the owner through each entry point and assert the route, the server,
/// and the parking, never which closure ran.
@Suite("AppOpener")
@MainActor
struct AppOpenerTests {
    // MARK: - Entry point → request

    @Test func localAskBannerTapCarriesItsServer() throws {
        let request = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [
                "kind": "ask",
                "askId": "ask-1",
                "sessionId": "child",
                "serverId": "server-b",
            ]
        ))

        #expect(request == .session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            origin: .externalURL
        )))
    }

    @Test func remotePushTapCarriesItsServerAndWorkspace() throws {
        let request = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.sessionBlockedCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [
                "event": "session.status",
                "serverId": "server-b",
                "sessionId": "child",
                "workspaceId": "workspace-b",
            ]
        ))

        #expect(request == .session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            workspaceId: "workspace-b",
            origin: .externalURL
        )))
    }

    /// Deny acts without opening Oppi, so only on an alert the push extension tagged: APNs shows
    /// a forged push that skips the extension with whatever category and fields it names.
    @Test func pairingNotificationMapsOpenApproveAndOnlyAnExtensionTaggedDeny() throws {
        let pushKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let keyId = Data(repeating: 7, count: PushEnvelope.keyIdLength)
        let keys = { (id: Data) -> PushKeyMaterial? in
            id == keyId ? PushKeyMaterial(privateKey: pushKey, serverPublicKey: Data(), serverId: "server-a") : nil
        }
        let forged = [
            "serverId": "server-a",
            "approvalId": "approval-1",
        ]
        let base = forged.merging(
            PushActionTag(keyId: keyId, privateKey: pushKey).userInfo(serverId: "server-a", approvalId: "approval-1")
        ) { _, tag in tag }
        func request(_ action: String, _ userInfo: [String: String]) -> AppOpenRequest? {
            AttentionNotificationService.openRequest(
                categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
                actionIdentifier: action,
                userInfo: userInfo,
                pushKey: keys
            )
        }
        let open = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: base
        ))
        let approve = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
            actionIdentifier: AttentionNotificationService.pairingApproveActionId,
            userInfo: base
        ))
        let deny = try #require(request(AttentionNotificationService.pairingDenyActionId, base))

        #expect(open == .pairing(serverId: "server-a", approvalId: "approval-1", action: .open))
        #expect(approve == .pairing(serverId: "server-a", approvalId: "approval-1", action: .approve))
        #expect(deny == .pairing(serverId: "server-a", approvalId: "approval-1", action: .deny))

        // Opening Oppi is all an untagged alert can do; the approval sheet shows what the server lists.
        #expect(request(AttentionNotificationService.pairingApproveActionId, forged)
            == .pairing(serverId: "server-a", approvalId: "approval-1", action: .approve))
        #expect(request(AttentionNotificationService.pairingDenyActionId, forged) == nil)
        // A tag binds its server and approval, and only this device's key for that server makes one.
        var otherApproval = base
        otherApproval["approvalId"] = "approval-2"
        #expect(request(AttentionNotificationService.pairingDenyActionId, otherApproval) == nil)
        var otherServer = base
        otherServer["serverId"] = "server-b"
        #expect(request(AttentionNotificationService.pairingDenyActionId, otherServer) == nil)
        let foreignKey = forged.merging(
            PushActionTag(keyId: keyId, privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
                .userInfo(serverId: "server-a", approvalId: "approval-1")
        ) { _, tag in tag }
        #expect(request(AttentionNotificationService.pairingDenyActionId, foreignKey) == nil)
        #expect(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.deviceEnrolledCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: ["serverId": "server-a"]
        ) == nil)
    }

    @Test func urlsMapToTheirOneRequest() throws {
        func request(_ raw: String) throws -> AppOpenRequest {
            AppOpenRequest(url: try #require(URL(string: raw)), origin: .externalURL)
        }

        #expect(try request("oppi://session/a%20b") == .session(SessionOpen(
            sessionId: "a b",
            origin: .externalURL
        )))
        // A URL must not choose the session's workspace (or its lock scope).
        #expect(try request("oppi://session/child?workspaceId=w1") == .session(SessionOpen(
            sessionId: "child",
            origin: .externalURL
        )))
        #expect(try request("oppi://workspace?path=/tmp/project&name=Project") == .createWorkspace(
            WorkspaceDeepLink.Payload(path: "/tmp/project", name: "Project", serverFingerprint: nil)
        ))
        #expect(try request("oppi://connect?v=3&invite=abc") == .invite(
            URL(string: "oppi://connect?v=3&invite=abc")!
        ))
        #expect(try request("https://example.com/docs") == .webLink(
            URL(string: "https://example.com/docs")!
        ))
        #expect(try request("mailto:support@example.com") == .system(
            URL(string: "mailto:support@example.com")!
        ))

        let reference = ResourceReference(
            target: "Build Notes",
            sourceServerID: "server-a",
            workspaceID: "workspace-a",
            sourceSessionID: "source",
            fileCandidatePath: "Build Notes.md"
        )
        let referenceURL = try #require(ResourceReferenceURL.make(reference))
        #expect(try request(referenceURL.absoluteString) == .resourceReference(reference))
    }

    @Test func malformedSessionURLsStayInvites() throws {
        // `oppi://session` with a nested path and a non-connect oppi link both
        // fall through to the invite route, which drops silently unless it
        // looks like a connect/pair link.
        for raw in ["oppi://session/a/b", "oppi://nonsense"] {
            let url = try #require(URL(string: raw))
            #expect(AppOpenRequest(url: url, origin: .externalURL) == .invite(url), Comment(rawValue: raw))
            #expect(!InAppInviteLink.claims(url), Comment(rawValue: raw))
        }
    }

    // MARK: - Warm and cold

    @Test func pushTapOpensTheSessionAndItsAskCard() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.setAskDialog(sessionId: "child", on: "server-a")

        harness.opener.open(try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: ["sessionId": "child", "serverId": "server-a"]
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.connection("server-a").focusedSessionId == "child")
        #expect(harness.connection("server-a").askRequestStore.pending(for: "child") != nil)
    }

    @Test func coldLaunchParksTheRequestUntilLaunchFinishes() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.opener._parkedRequestForTesting != nil)

        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func aRequestParkedBeforeThePairingListIsReadStillOpens() async throws {
        // A locked launch has not read the pairing list yet: its server is
        // unread, not removed, however often the root redraws.
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false, loadsServers: false)
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.sceneDidBecomeActive()
        harness.opener.presentationDidUpdate()
        #expect(harness.opener._parkedRequestForTesting != nil)

        harness.serverStore.load()
        harness.opener.launchDidFinish()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func twoRequestsBeforeLaunchOpenOnlyTheLast() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("first", workspaceId: "w1", to: "server-a")
        harness.addSession("second", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "first",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "second",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "second")
    }

    @Test func workspaceURLAtColdLaunchOpensTheCreateFormOnItsServer() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        let url = try #require(URL(string: "oppi://workspace?path=/tmp/project&name=Project"))

        harness.opener.open(AppOpenRequest(url: url, origin: .externalURL))
        await harness.settle()
        #expect(harness.navigation.pendingWorkspaceDeepLink == nil)

        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        let payload = try #require(harness.navigation.pendingWorkspaceDeepLink)
        #expect(payload.path == "/tmp/project")
        #expect(payload.name == "Project")
        #expect(payload.resolvedServerId == "server-a")
        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func inAppSessionLinkAtColdLaunchParksUntilLaunch() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("source", workspaceId: "w1", to: "server-a")
        harness.addSession("target", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "w1"
        ))

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "target",
            origin: .inAppHyperlink
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.count == 1)

        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func sceneSessionURLWaitsForUnlock() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        let url = try #require(URL(string: "oppi://session/child"))

        harness.opener.open(AppOpenRequest(url: url, origin: .externalURL))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    // MARK: - In-app links

    @Test func timelineSessionLinkKeepsTheBackStackAndPreparesTheTarget() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "w1", to: "server-a")
        harness.addSession("target", workspaceId: "w1", to: "server-a")
        harness.setAskDialog(sessionId: "target", on: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "w1"
        ))

        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/target")),
            origin: .inAppHyperlink,
            sourceServerID: "server-a"
        ))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 2)
        harness.expectSessionRoute(serverId: "server-a", sessionId: "target")
        #expect(harness.connection("server-a").askRequestStore.pending(for: "target") != nil)
    }

    @Test func extensionSurfaceSessionLinkNavigatesLikeATimelineLink() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "chat-workspace", to: "server-a")
        harness.addSession("target", workspaceId: "chat-workspace", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "chat-workspace"
        ))

        // A widget's `oppi://session/<id>` link from the chat carries the
        // chat's server and workspace, exactly like a timeline link.
        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/target?workspaceId=chat-workspace")),
            origin: .inAppHyperlink,
            sourceServerID: "server-a"
        ))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 2)
        let route = try #require(harness.lastSessionRoute)
        #expect(route.sessionId == "target")
        #expect(route.workspaceId == "chat-workspace")
    }

    @Test func selfLinkToTheVisibleChatDoesNothing() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "w1"
        ))
        let connection = harness.connection("server-a")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.focusSession("source")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "source",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func staleInAppLinkIsDroppedInsteadOfGuessed() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("other", workspaceId: "w1", to: "server-b")
        harness.addSession("target", workspaceId: "w1", to: "server-b")

        // The source server does not have the session: do not fall back to a
        // global guess.
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "target",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.coordinator.activeServerId == "server-a")
    }

    @Test func inAppLinkWithoutASourceUsesTheUniqueMatch() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("target", workspaceId: "w1", to: "server-b")

        harness.opener.open(.session(SessionOpen(
            sessionId: "target",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-b", sessionId: "target")
    }

    // MARK: - Servers

    @Test func pushForAnotherServerSwitchesAndRoutesThere() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("child", workspaceId: "workspace-b", to: "server-b")
        #expect(harness.coordinator.activeServerId == "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-b")
        harness.expectSessionRoute(serverId: "server-b", sessionId: "child")
    }

    @Test func sceneSessionURLResolvesThroughTheCachedStores() async throws {
        // A session created by the share extension is not in memory until the
        // app asks its server for it.
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.coordinator._getSessionRecordForTesting = { _, id in
            makeTestSession(id: id, workspaceId: "w1", status: .busy)
        }

        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/shared-session")),
            origin: .externalURL
        ))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "shared-session")
    }

    @Test func unknownServerShowsAToastAndDropsTheRequest() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])

        harness.opener.open(.session(SessionOpen(
            serverId: "unpaired-server",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.connection("server-a").extensionToast == "Server not found for this session link")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    // MARK: - Thread links

    @Test func threadURLsMapToAThreadRequestWithTheSessionLinksValidation() throws {
        func request(_ raw: String, origin: SessionNavigationSource = .externalURL, server: String? = nil) throws -> AppOpenRequest {
            AppOpenRequest(url: try #require(URL(string: raw)), origin: origin, sourceServerID: server)
        }

        #expect(try request("oppi://thread/root-1") == .thread(SessionOpen(sessionId: "root-1", origin: .externalURL)))
        #expect(try request("oppi://thread/a%20b") == .thread(SessionOpen(sessionId: "a b", origin: .externalURL)))
        // A URL must not choose the session's workspace (or its lock scope).
        #expect(try request("oppi://thread/child?workspaceId=w1") == .thread(SessionOpen(sessionId: "child", origin: .externalURL)))
        // A link inside Oppi carries its source server.
        #expect(try request("oppi://thread/child", origin: .inAppHyperlink, server: "server-a") == .thread(SessionOpen(
            serverId: "server-a", sessionId: "child", origin: .inAppHyperlink
        )))
        for raw in ["oppi://thread", "oppi://thread/", "oppi://thread/a/b"] {
            let url = try #require(URL(string: raw))
            #expect(AppOpenRequest(url: url, origin: .externalURL) == .invite(url), Comment(rawValue: raw))
        }
    }

    @Test func aThreadLinkToADescendantOpensItsRootsThreadInTheList() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("root", workspaceId: "w1", to: "server-a")
        harness.addSession("child", parent: "root", workspaceId: "w1", to: "server-a")
        harness.addSession("grandchild", parent: "child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "grandchild", origin: .externalURL)))
        await harness.settle()

        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "root"))
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty, "The link lands on the list, not a chat")
        #expect(harness.connection("server-a").extensionToast == nil)

        // The root's own link opens its own thread.
        harness.navigation.pendingThreadFocus = nil
        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "root", origin: .externalURL)))
        await harness.settle()
        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "root"))
    }

    @Test func aThreadLinkReadsAncestorsThatAreNotLoadedToFindTheRoot() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("grandchild", parent: "child", workspaceId: "w1", to: "server-a")
        harness.connection("server-a")._getSessionRecordForTesting = { id in
            var session = makeTestSession(id: id, workspaceId: "w1", status: .stopped)
            session.parentSessionId = ["grandchild": "child", "child": "root"][id]
            return session
        }

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "grandchild", origin: .externalURL)))
        await harness.settle()

        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "root"))
    }

    @Test func aThreadLinkSwitchesToTheServerThatHasTheSession() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("root", workspaceId: "w1", to: "server-b")
        harness.addSession("child", parent: "root", workspaceId: "w1", to: "server-b")

        harness.opener.open(.thread(SessionOpen(serverId: "server-b", sessionId: "child", origin: .externalURL)))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-b")
        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-b", rootId: "root"))
    }

    @Test func aThreadLinkToAnUnknownSessionShowsTheListAndANotice() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        // The server answers 404: it does not have the session.
        harness.connection("server-a")._getSessionRecordForTesting = { _ in throw APIError.server(status: 404, message: "Not found") }
        harness.coordinator._getSessionRecordForTesting = { _, _ in throw APIError.server(status: 404, message: "Not found") }

        // Named server, and a link that names none.
        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "gone", origin: .externalURL)))
        await harness.settle()
        #expect(harness.navigation.pendingThreadFocus == nil)
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.connection("server-a").extensionToast == "Session not found for this thread link")

        harness.connection("server-a").extensionToast = nil
        harness.opener.open(.thread(SessionOpen(sessionId: "gone", origin: .externalURL)))
        await harness.settle()
        #expect(harness.navigation.pendingThreadFocus == nil)
        #expect(harness.connection("server-a").extensionToast == "Session not found for this thread link")
    }

    /// A server that did not answer is not a session that does not exist: no "not found" notice, the list
    /// stays where it was, and the request waits for the next foreground like an unreachable session link.
    @Test func aThreadLinkThatCouldNotAskTheServerIsNotANotFound() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.connection("server-a")._getSessionRecordForTesting = { _ in throw URLError(.notConnectedToInternet) }
        harness.coordinator._getSessionRecordForTesting = { _, _ in throw URLError(.notConnectedToInternet) }
        harness.navigation.openWorkspaceSession(.init(serverId: "server-a", sessionId: "current", workspaceId: "w1"))

        for link in [
            SessionOpen(serverId: "server-a", sessionId: "gone", origin: .externalURL),
            SessionOpen(sessionId: "gone", origin: .externalURL),
        ] {
            harness.connection("server-a").extensionToast = nil
            harness.opener.open(.thread(link))
            await harness.settle()

            #expect(harness.navigation.pendingThreadFocus == nil)
            #expect(!harness.navigation.workspaceStackRouteElements.isEmpty, "The screen is not reset for a link that did not resolve")
            #expect(harness.connection("server-a").extensionToast == "Could not reach server-a")
            #expect(harness.opener._parkedRequestForTesting == .thread(link))
        }
    }

    /// A newer open supersedes a thread link that is still reading an ancestor: the older link must not
    /// open its thread when the read returns.
    @Test func aNewerLinkWinsOverAThreadLinkStillReadingAnAncestor() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("grandchild", parent: "child", workspaceId: "w1", to: "server-a")
        harness.addSession("other-root", workspaceId: "w1", to: "server-a")
        var release: CheckedContinuation<Void, Never>?
        harness.connection("server-a")._getSessionRecordForTesting = { id in
            if id == "child" { await withCheckedContinuation { release = $0 } }
            var session = makeTestSession(id: id, workspaceId: "w1", status: .stopped)
            session.parentSessionId = ["grandchild": "child", "child": "root"][id]
            return session
        }

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "grandchild", origin: .externalURL)))
        for _ in 0..<500 where release == nil { await Task.yield() }
        #expect(release != nil, "The first link should be reading its missing ancestor")

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "other-root", origin: .externalURL)))
        await harness.settle()
        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "other-root"))

        harness.navigation.pendingThreadFocus = nil
        release?.resume()
        for _ in 0..<200 { await Task.yield() }
        #expect(harness.navigation.pendingThreadFocus == nil, "The superseded link must not open its thread")
    }

    /// The lock gate is the session link's: a record that names a locked workspace is refused after it loads.
    @Test func aThreadLinkToASessionInALockedWorkspaceIsRefusedAndRestoresTheServer() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        let target = harness.connection("server-b")
        // Only the loaded record names the locked workspace, so the gate before the switch cannot know it.
        target._getSessionRecordForTesting = { id in makeTestSession(id: id, workspaceId: "w2", status: .busy) }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-b", workspaceId: "w2"))

        harness.opener.open(.thread(SessionOpen(serverId: "server-b", sessionId: "locked", origin: .externalURL)))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.navigation.pendingThreadFocus == nil)
    }

    // MARK: - Loaded sessions open before the network answers

    /// A slow network (Tailscale SOCKS) must not hold a link to a session the phone already has: the
    /// route is up while the record refresh is still out, and the refresh lands behind it.
    @Test func aLoadedSessionLinkPushesBeforeTheRecordRefreshReturns() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        let connection = harness.connection("server-a")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            return makeTestSession(id: id, workspaceId: "w1", status: .stopped)
        }
        var dialogReads = 0
        connection._getSessionDialogsForTesting = { _ in
            dialogReads += 1
            return APIClient.SessionDialogsResponse(dialogs: [], serverNow: 1)
        }
        var logged: [String: String] = [:]
        harness.opener._linkOpenedForTesting = { logged = $0 }

        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "child", origin: .inAppHyperlink)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(release != nil, "The refresh is still out when the route is up")
        #expect(dialogReads == 0)
        #expect(connection.sessionStore.session(id: "child")?.status == .busy, "The chat opens from the cached record")
        #expect(logged["path"] == "cached")
        #expect(logged["recordRefreshMs"] == nil)

        release?.resume()
        await harness.settle()
        #expect(connection.sessionStore.session(id: "child")?.status == .stopped, "The refresh still lands")
        #expect(dialogReads == 1, "Pending dialogs still hydrate behind the route")
        #expect(harness.traceReads == 0, "The chat loads its own timeline; a late prefetch could overwrite its cache")
    }

    /// Only a record that names its workspace gives the lock scope; any other session still waits for
    /// the record before it is pushed, so a locked workspace can never be shown early.
    @Test func aSessionThatIsNotLoadedStillWaitsForItsRecordBeforeTheRoute() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        let connection = harness.connection("server-a")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            return makeTestSession(id: id, workspaceId: "w1", status: .busy)
        }
        var logged: [String: String] = [:]
        harness.opener._linkOpenedForTesting = { logged = $0 }

        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "fresh", origin: .externalURL)))
        for _ in 0..<500 where release == nil { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(release != nil)
        #expect(harness.lastSessionRoute == nil, "No record yet: nothing to gate on")

        release?.resume()
        await harness.settle()
        harness.expectSessionRoute(serverId: "server-a", sessionId: "fresh")
        #expect(logged["path"] == "blocking")
    }

    /// The cached record names a locked workspace: the prompt comes before the route and before the
    /// refresh, and a cancel leaves focus, the claim, and the route untouched.
    @Test func aLoadedSessionInALockedWorkspaceAsksBeforeItOpensAndCancelLeavesNothing() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], authOutcomes: [.cancelled])
        harness.addSession("locked", workspaceId: "w2", to: "server-a")
        let connection = harness.connection("server-a")
        var refreshes = 0
        connection._getSessionRecordForTesting = { id in
            refreshes += 1
            return makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-a", workspaceId: "w2"))

        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "locked", origin: .inAppHyperlink)))
        await harness.settle()

        #expect(harness.lastSessionRoute == nil)
        #expect(refreshes == 0)
        #expect(connection.sessionStore.activeSessionId == nil)
        #expect(connection.focusedSessionId == nil)
        #expect(!connection.externalSessionOpenClaimBlocks("other"))
    }

    /// A successful unlock opens the loaded session without waiting for the network either.
    @Test func aLoadedSessionInALockedWorkspaceOpensAfterUnlockBeforeTheRefreshReturns() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], authOutcomes: [.success])
        harness.addSession("locked", workspaceId: "w2", to: "server-a")
        let connection = harness.connection("server-a")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            return makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-a", workspaceId: "w2"))

        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "locked", origin: .inAppHyperlink)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }

        harness.expectSessionRoute(serverId: "server-a", sessionId: "locked")
        #expect(release != nil)
        release?.resume()
        await harness.settle()
    }

    /// A refreshed record can move the session (a re-import into another workspace, a terminal
    /// takeover) into a locked workspace the cache did not know. The route is taken off the stack when
    /// the prompt is cancelled, the server the open switched away from comes back, and nothing else
    /// about the session loads.
    @Test func aLockDiscoveredOnlyByTheRefreshTakesTheOpenedSessionBackOffScreen() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-b")
        let connection = harness.connection("server-b")
        var release: CheckedContinuation<Void, Never>?
        var dialogReads = 0
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            return makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        connection._getSessionDialogsForTesting = { _ in
            dialogReads += 1
            return APIClient.SessionDialogsResponse(dialogs: [], serverNow: 1)
        }
        harness.lockWorkspace("w2", on: "server-b")

        harness.opener.open(.session(SessionOpen(serverId: "server-b", sessionId: "child", origin: .externalURL)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }
        harness.expectSessionRoute(serverId: "server-b", sessionId: "child")

        release?.resume()
        await harness.settle()

        #expect(harness.lastSessionRoute == nil, "The locked workspace's session is not left on screen")
        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(dialogReads == 0, "Nothing else about the session loads after the cancel")
        #expect(connection.sessionStore.activeSessionId == nil)
        #expect(!connection.externalSessionOpenClaimBlocks("other"))
    }

    /// An open a newer one replaced asks nobody (the route's own gate covers the moved session), but
    /// its refresh still lands: the store must hold the session's new workspace for that gate, and for
    /// Back to the chat later. A real request is cancelled with its task, so the stub fails when it is.
    @Test func aSupersededLoadedOpenStillLandsItsRefreshButNeverPrompts() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], authOutcomes: [.cancelled])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.addSession("other", workspaceId: "w1", to: "server-a")
        let connection = harness.connection("server-a")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            if id == "child" {
                await withCheckedContinuation { release = $0 }
                try Task.checkCancellation()
            }
            return makeTestSession(id: id, workspaceId: id == "child" ? "w2" : "w1", status: .busy)
        }
        harness.lockWorkspace("w2", on: "server-a")

        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "child", origin: .inAppHyperlink)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }
        harness.opener.open(.session(SessionOpen(serverId: "server-a", sessionId: "other", origin: .inAppHyperlink)))
        for _ in 0..<500 where harness.lastSessionRoute?.sessionId != "other" { await Task.yield() }
        harness.expectSessionRoute(serverId: "server-a", sessionId: "other")

        release?.resume()
        for _ in 0..<500 where connection.sessionStore.session(id: "child")?.workspaceId != "w2" { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }

        #expect(connection.sessionStore.session(id: "child")?.workspaceId == "w2", "The refresh lands in the store")
        #expect(harness.authenticator.prompts == 0, "A replaced open must not prompt")
        #expect(harness.stackSessionIds == ["child", "other"], "The newer open's screen is untouched")
    }

    /// The prompt is already up when a newer open replaces this one. A refusal still takes the locked
    /// session's route off the stack, so Back from the newer screen never reaches its chat, and it
    /// leaves the newer screen (and the server it is on) alone.
    @Test func aRefusedLockTakesTheSessionOffTheStackEvenIfAnotherOpenReplacedItWhileAsking() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-b")
        harness.addSession("other", workspaceId: "w1", to: "server-b")
        let connection = harness.connection("server-b")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            if id == "child" { await withCheckedContinuation { release = $0 } }
            return makeTestSession(id: id, workspaceId: id == "child" ? "w2" : "w1", status: .busy)
        }
        harness.lockWorkspace("w2", on: "server-b")
        harness.authenticator.holdsPrompts = true

        harness.opener.open(.session(SessionOpen(serverId: "server-b", sessionId: "child", origin: .inAppHyperlink)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }
        release?.resume()
        for _ in 0..<500 where !harness.authenticator.isAsking { await Task.yield() }
        #expect(harness.authenticator.isAsking, "The refreshed lock scope asks")

        harness.opener.open(.session(SessionOpen(serverId: "server-b", sessionId: "other", origin: .inAppHyperlink)))
        for _ in 0..<500 where harness.lastSessionRoute?.sessionId != "other" { await Task.yield() }
        harness.expectSessionRoute(serverId: "server-b", sessionId: "other")

        harness.authenticator.answer(.cancelled)
        for _ in 0..<500 where harness.stackSessionIds.contains("child") { await Task.yield() }

        #expect(harness.stackSessionIds == ["other"], "Back must not reach the locked session")
        #expect(harness.coordinator.activeServerId == "server-b", "The newer open owns the server")
    }

    /// The person tapped another screen themselves (the opener never heard of it) before the refused
    /// prompt: the locked session's route goes, the screen they chose and its server stay.
    @Test func aRefusedLockAfterTheUserNavigatedOnLeavesTheirScreenAndServerAlone() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-b")
        let connection = harness.connection("server-b")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            return makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        harness.lockWorkspace("w2", on: "server-b")

        harness.opener.open(.session(SessionOpen(serverId: "server-b", sessionId: "child", origin: .inAppHyperlink)))
        for _ in 0..<500 where release == nil || harness.lastSessionRoute == nil { await Task.yield() }
        harness.navigation.openReferencedSession(WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "manual",
            workspaceId: "w1"
        ))

        release?.resume()
        await harness.settle()

        #expect(harness.stackSessionIds == ["manual"])
        #expect(harness.coordinator.activeServerId == "server-b", "Only a session still on screen restores the server")
    }

    @Test func aLoadedThreadLinkOpensBeforeTheRecordRefreshReturns() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("root", workspaceId: "w1", to: "server-a")
        harness.addSession("child", parent: "root", workspaceId: "w1", to: "server-a")
        let connection = harness.connection("server-a")
        var release: CheckedContinuation<Void, Never>?
        connection._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            var session = makeTestSession(id: id, workspaceId: "w1", status: .busy)
            session.parentSessionId = "root"
            return session
        }

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "child", origin: .externalURL)))
        for _ in 0..<500 where release == nil || harness.navigation.pendingThreadFocus == nil { await Task.yield() }

        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "root"))
        #expect(release != nil, "The refresh is still out when the thread is open")
        release?.resume()
        await harness.settle()
    }

    /// The thread is already open when the refresh says the session is gone: a notice, not a silent miss.
    @Test func aLoadedThreadLinkToASessionTheRefreshSaysIsGoneToastsAfterOpening() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("root", workspaceId: "w1", to: "server-a")
        harness.addSession("child", parent: "root", workspaceId: "w1", to: "server-a")
        harness.connection("server-a")._getSessionRecordForTesting = { _ in
            throw APIError.server(status: 404, message: "Not found")
        }

        harness.opener.open(.thread(SessionOpen(serverId: "server-a", sessionId: "child", origin: .externalURL)))
        await harness.settle()

        #expect(harness.navigation.pendingThreadFocus == .init(serverId: "server-a", rootId: "root"))
        #expect(harness.connection("server-a").extensionToast == "Session not found for this thread link")
    }

    /// The refresh moves a thread's session into a locked workspace and the prompt is refused: while
    /// the list the link opened is still showing, the server comes back; once the person has gone on
    /// to another screen, nothing of theirs moves.
    @Test(arguments: [false, true])
    func aRefusedLockAfterAThreadOpensRestoresTheServerOnlyWhileTheListIsShowing(navigatedOn: Bool) async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("root", workspaceId: "w1", to: "server-b")
        harness.addSession("child", parent: "root", workspaceId: "w1", to: "server-b")
        var release: CheckedContinuation<Void, Never>?
        harness.connection("server-b")._getSessionRecordForTesting = { id in
            await withCheckedContinuation { release = $0 }
            var session = makeTestSession(id: id, workspaceId: "w2", status: .busy)
            session.parentSessionId = id == "child" ? "root" : nil
            return session
        }
        harness.lockWorkspace("w2", on: "server-b")

        harness.opener.open(.thread(SessionOpen(serverId: "server-b", sessionId: "child", origin: .externalURL)))
        for _ in 0..<500 where release == nil || harness.navigation.pendingThreadFocus == nil { await Task.yield() }
        if navigatedOn {
            harness.navigation.openReferencedSession(WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "manual",
                workspaceId: "w1"
            ))
        }
        release?.resume()
        await harness.settle()

        #expect(harness.coordinator.activeServerId == (navigatedOn ? "server-b" : "server-a"))
        #expect(harness.stackSessionIds == (navigatedOn ? ["manual"] : []))
    }

    @Test func unreachableServerKeepsTheRequestAndRetriesOnTheNextForeground() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.connection("server-a").extensionToast == "Could not reach server-a")
        #expect(harness.opener._parkedRequestForTesting != nil)

        // Still down: one more foreground attempt, still parked.
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        harness.unreachableServers = []
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    @Test func aNewerRequestReplacesTheParkedOne() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("first", workspaceId: "w1", to: "server-a")
        harness.addSession("second", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "first",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "second",
            origin: .externalURL
        )))
        await harness.settle()

        harness.unreachableServers = []
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "second")
    }

    // MARK: - App Lock and scoped locks

    @Test(arguments: [
        AppLockUnlockOutcome.success,
        AppLockUnlockOutcome.cancelled,
        AppLockUnlockOutcome.backgrounded,
    ])
    func lockedOpenWaitsForUnlock(_ outcome: AppLockUnlockOutcome) async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            authOutcomes: outcome == .success ? [.success] : [.cancelled]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        switch outcome {
        case .success:
            #expect(await harness.appLock.unlock())
            await harness.settle()
            harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        case .cancelled:
            #expect(!(await harness.appLock.unlock()))
            await harness.settle()
            #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        case .backgrounded:
            harness.appLock.appDidEnterBackground()
            await harness.settle()
            #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        }
    }

    @Test func aLockedOpenNeverPairsOrNavigatesBehindTheCover() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        harness.opener.open(.webLink(try #require(URL(string: "https://example.com/docs"))))
        await harness.settle()

        #expect(harness.recorder.browserURLs.isEmpty)
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func cancelledScopedUnlockLeavesServerAndRouteAlone() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("current", workspaceId: "w1", to: "server-a")
        harness.addSession("locked", workspaceId: "w2", to: "server-b")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "current",
            workspaceId: "w1"
        ))
        harness.scopedLock.lock(.session(serverId: "server-b", sessionId: "locked"), workspaceId: "w2")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-b",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-a")
        harness.expectSessionRoute(serverId: "server-a", sessionId: "current")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    // MARK: - Invites

    @Test func inviteRunsDuringLaunchWithoutWaiting() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        let url = try #require(URL(string: "oppi://connect?v=3&invite=bogus"))

        harness.opener.open(.invite(url))
        await harness.settle()

        #expect(harness.connection("server-a").extensionToast == "Unsupported invite link format")
    }

    @Test func sessionRequestDuringInviteBootstrapOpensAfterItFinishes() async throws {
        // The invite holds the app; a session tap that arrives then must not be
        // lost. This is the regression for the one-shot launch consume.
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        let attempt = harness.opener.invitePairingGate.beginIncoming()
        harness.opener.invitePairingGate.markStarted(attempt)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        harness.opener.invitePairingGate.markFinished(attempt)
        harness.opener.drainParkedIfPossible()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func workspaceLinkWaitsForUnlock() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately
        )
        harness.navigation.launchPhase = .ready
        harness.navigation.showOnboarding = false
        let url = try #require(URL(string: "oppi://workspace?path=/tmp/project&name=Locked"))

        harness.opener.open(AppOpenRequest(url: url, origin: .externalURL))
        await harness.settle()
        #expect(harness.navigation.pendingWorkspaceDeepLink == nil)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        #expect(harness.navigation.pendingWorkspaceDeepLink?.path == "/tmp/project")
    }

    @Test func inviteWaitsForThePairingList() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        var releaseLoad: CheckedContinuation<Void, Never>?
        harness.opener.awaitPairedServers = {
            await withCheckedContinuation { releaseLoad = $0 }
        }

        harness.opener.open(.invite(try #require(URL(string: "oppi://connect?v=3&invite=bogus"))))
        for _ in 0..<1_000 where releaseLoad == nil {
            await Task.yield()
        }
        let release = try #require(releaseLoad)
        #expect(harness.connection("server-a").extensionToast == nil)

        release.resume()
        await harness.settle()
        #expect(harness.connection("server-a").extensionToast == "Unsupported invite link format")
    }

    @Test func inviteWaitsForUnlock() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            launch: false
        )
        harness.opener.open(.invite(try #require(URL(string: "oppi://connect?v=3&invite=bogus"))))
        await harness.settle()
        #expect(harness.connection("server-a").extensionToast == nil)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        #expect(harness.connection("server-a").extensionToast == "Unsupported invite link format")
    }

    @Test func quickSessionWaitsForUnlock() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            launch: false
        )
        harness.navigation.launchPhase = .ready
        harness.navigation.showOnboarding = false
        harness.opener.launchDidFinish()

        harness.opener.open(.quickSession(QuickSessionStart(mode: .message)))
        await harness.settle()
        #expect(!harness.navigation.showQuickSession)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        #expect(harness.navigation.showQuickSession)
    }

    // MARK: - Siri and Quick Session

    @Test func siriReceiptOpensWithTheCreatedRowAndDraft() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        let receipt = IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Write the release notes",
            session: makeTestSession(id: "created", workspaceId: "w1", status: .busy)
        )
        harness.intentTrigger.enqueue(receipt)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            origin: .externalURL,
            startedSessionRequestID: receipt.requestID
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "created")
        #expect(harness.connection("server-a").sessionStore.session(id: "created") != nil)
        let key = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "w1",
            sessionID: "created"
        ))
        #expect(harness.composerDraftStore.record(for: key)?.payload.text == "Write the release notes")
        #expect(harness.intentTrigger.peek() == nil)
    }

    @Test func leftoverSiriReceiptOpensAtLaunch() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.intentTrigger.enqueue(IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: nil,
            session: nil
        ))

        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "created")
    }

    @Test func quickSessionWaitsForLaunchAndDropsWhenOneIsShowing() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.navigation.launchPhase = .ready
        harness.navigation.showOnboarding = false

        harness.opener.open(.quickSession(QuickSessionStart(mode: .dictation)))
        await harness.settle()
        #expect(!harness.navigation.showQuickSession)

        harness.opener.launchDidFinish()
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.showQuickSession)
        #expect(harness.navigation.pendingQuickSessionStart?.mode == .dictation)

        // A second request while the sheet is up is dropped, never queued.
        harness.opener.open(.quickSession(QuickSessionStart(mode: .liveVoice)))
        await harness.settle()
        #expect(harness.navigation.pendingQuickSessionStart?.mode == .dictation)
    }

    // MARK: - Repair: App Lock, lock scope, lifetime

    @Test func parkedRequestWaitsForUnlockBeforeDraining() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled, .success],
            launch: false
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.opener._parkedRequestForTesting != nil)

        // The request is parked for launch; lock the app before launch finishes.
        harness.appLock.setTimeout(.immediately)
        harness.appLock.appDidEnterBackground()
        harness.opener.sceneDidEnterBackground()
        harness.opener.launchDidFinish()

        // Foreground auto-prompts once; cancel it and stay locked.
        if let autoUnlock = harness.appLock.sceneDidBecomeActive() {
            #expect(await autoUnlock.value == false)
        }
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func scopedLockedTargetBehindAppLockStillAsks() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            authOutcomes: [.success, .success]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.scopedLock.lock(
            .session(serverId: "server-a", sessionId: "child"),
            workspaceId: "w1"
        )

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        // App Lock's deferred request ran the scoped gate, which asked and
        // succeeded; it was not silently dropped behind the lock.
        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func urlWorkspaceHintCannotChooseTheScopedLockScope() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        // The session lives on the non-active server, so a pre-switch pass
        // would also switch servers.
        harness.addSession("child", workspaceId: "w1", to: "server-b")
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        // The session's workspace is locked.
        harness.scopedLock.lock(
            .workspace(serverId: "server-b", workspaceId: "w1")
        )

        // A URL hint must not move the lock scope off that workspace.
        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/child?workspaceId=other")),
            origin: .externalURL
        ))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func quickSessionParkedDuringOnboardingOpensWhenItClears() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.navigation.launchPhase = .ready
        harness.navigation.showOnboarding = true

        harness.opener.open(.quickSession(QuickSessionStart(mode: .message)))
        await harness.settle()
        #expect(!harness.navigation.showQuickSession)

        harness.navigation.showOnboarding = false
        harness.opener.presentationDidUpdate()
        await harness.settle()
        #expect(harness.navigation.showQuickSession)
    }

    @Test func staleParkedRequestIsDropped() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.opener._parkedRequestForTesting != nil)

        let later = Date().addingTimeInterval(601)
        harness.opener._nowForTesting = { later }
        harness.unreachableServers = []
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        #expect(harness.opener._parkedRequestForTesting == nil)
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func removingTheServerDropsAParkedRequest() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.opener._parkedRequestForTesting != nil)

        harness.serverStore.remove(id: "server-a")
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        #expect(harness.opener._parkedRequestForTesting == nil)
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func aNewerOpenAbandonsTheParkedSiriReceipt() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.opener._browserLinkPreferenceForTesting = .inApp
        let receipt = IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Do the thing",
            session: nil
        )
        harness.intentTrigger.enqueue(receipt)
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            origin: .externalURL,
            startedSessionRequestID: receipt.requestID
        )))
        await harness.settle()
        #expect(harness.opener._parkedRequestForTesting != nil)

        let url = try #require(URL(string: "https://example.com/newer"))
        harness.opener.open(.webLink(url))
        await harness.settle()

        // The newer request wins, and the superseded Siri receipt will not
        // replay at a later launch.
        #expect(harness.intentTrigger.peek() == nil)
        #expect(harness.recorder.browserURLs == [url])
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    @Test func aReceiptForAnUnpairedServerIsTakenAndForgotten() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.intentTrigger.enqueue(IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-gone",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: nil,
            session: nil
        ))

        harness.opener.launchDidFinish()
        await harness.settle()

        #expect(harness.intentTrigger.peek() == nil)
        #expect(harness.connection("server-a").extensionToast == "Server not found for this session link")
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    // MARK: - Repair 2: deferred opens, receipts, destination scope

    @Test func aLockedReceiptDoesNotTakeTheUsersTap() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            launch: false
        )
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.addSession("tapped", workspaceId: "w1", to: "server-a")
        let receipt = IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: nil,
            session: nil
        )
        harness.intentTrigger.enqueue(receipt)

        // Cold + locked: the leftover receipt waits behind App Lock.
        harness.opener.launchDidFinish()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        // The user's tap arrives while the receipt is still deferred.
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "tapped",
            origin: .externalURL
        )))
        await harness.settle()
        // Newest wins, and the superseded receipt must not replay later.
        #expect(harness.intentTrigger.peek() == nil)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        harness.expectSessionRoute(serverId: "server-a", sessionId: "tapped")
    }

    @Test func cancelledUnlockThenUnlockStillDrainsTheParkedRequest() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled, .cancelled, .success],
            launch: false
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        harness.appLock.setTimeout(.immediately)
        harness.appLock.appDidEnterBackground()
        harness.opener.sceneDidEnterBackground()
        harness.opener.launchDidFinish()

        // Foreground auto-prompts; cancel it and stay locked.
        if let autoUnlock = harness.appLock.sceneDidBecomeActive() {
            #expect(await autoUnlock.value == false)
        }
        // Arm the deferred drain, then cancel an explicit unlock: App Lock
        // drops its one deferred action.
        harness.opener.sceneDidBecomeActive()
        #expect(!(await harness.appLock.unlock()))
        // A second foreground must re-arm it; the old flag would skip this.
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        #expect(await harness.appLock.unlock())
        await harness.settle()
        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    // MARK: - Repair 3: dropped unlocks, stale choices, loaded scope, old receipts

    @Test func aCancelledUnlockKeepsTheDeferredSiriReceiptAndPrompt() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            authOutcomes: [.cancelled],
            launch: false
        )
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.opener._browserLinkPreferenceForTesting = .inApp
        harness.intentTrigger.enqueue(IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Write the release notes",
            session: nil
        ))

        // Cold + locked: the leftover receipt's open waits behind App Lock.
        harness.opener.launchDidFinish()
        await harness.settle()
        // Cancelling Face ID drops that open; the receipt was never superseded.
        #expect(!(await harness.appLock.unlock()))

        harness.opener.open(.webLink(try #require(URL(string: "https://example.com/later"))))
        await harness.settle()

        #expect(harness.intentTrigger.peek()?.unsentPrompt == "Write the release notes")
    }

    @Test func aStaleResourceChoiceCannotCancelANewerOpen() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("shared-id", workspaceId: "w1", to: "server-a")
        harness.addSession("shared-id", workspaceId: "w2", to: "server-b")
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.opener.open(.resourceReference(ambiguousSessionReference("shared-id")))
        await harness.settle()
        #expect(harness.opener.pendingResourceReferenceChoice?.matches.count == 2)

        // A notification tap opens a session while the choice sheet is up,
        // and the stale sheet's Cancel lands before that open finishes.
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        harness.opener.cancelResourceReferenceRequest()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(harness.opener.pendingResourceReferenceChoice == nil)
    }

    @Test func aChosenMatchOnAnUnreachableServerParksForTheNextForeground() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("shared-id", workspaceId: "w1", to: "server-a")
        harness.addSession("shared-id", workspaceId: "w2", to: "server-b")
        let reference = ambiguousSessionReference("shared-id")
        harness.opener.open(.resourceReference(reference))
        await harness.settle()
        let choice = try #require(harness.opener.pendingResourceReferenceChoice)
        let serverBMatch = try #require(choice.matches.first {
            if case .session(let session) = $0 { return session.serverID == "server-b" }
            return false
        })

        harness.unreachableServers = ["server-b"]
        harness.opener.startOpeningResourceReferenceMatch(serverBMatch)
        await harness.settle()

        #expect(harness.connection("server-a").extensionToast == "Could not reach server-b")
        #expect(harness.opener._parkedRequestForTesting == .resourceReference(reference))
    }

    @Test func cancellingTheLoadedWorkspaceLockRestoresTheServerAndActiveSession() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("current", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "current",
            workspaceId: "w1"
        ))
        // The session is not cached: only its loaded record names the locked
        // workspace, so the gate before the switch cannot know it.
        let target = harness.connection("server-b")
        target._getSessionRecordForTesting = { id in
            makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-b", workspaceId: "w2"))

        harness.opener.open(.session(SessionOpen(
            serverId: "server-b",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-a")
        harness.expectSessionRoute(serverId: "server-a", sessionId: "current")
        #expect(target.sessionStore.activeSessionId == nil)
        // The abandoned open no longer refuses another session's focus.
        #expect(!target.externalSessionOpenClaimBlocks("other"))
    }

    @Test func aSiriReceiptOlderThanAParkedRequestKeepsItsPromptButDoesNotOpen() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.intentTrigger.enqueue(IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Write the release notes",
            session: nil
        ))

        // The receipt lost its launch slot; a launch 10 minutes later is not
        // the moment the person asked Siri.
        let later = Date().addingTimeInterval(601)
        harness.opener._nowForTesting = { later }
        harness.opener.launchDidFinish()
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.intentTrigger.peek() == nil)
        let key = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "w1",
            sessionID: "created"
        ))
        #expect(harness.composerDraftStore.record(for: key)?.payload.text == "Write the release notes")
    }

    @Test func cancellingTheWorkspaceLockOnTheSameServerKeepsTheVisibleChatFocused() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("current", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "current",
            workspaceId: "w1"
        ))
        let connection = harness.connection("server-a")
        connection.focusSession("current")
        // Not cached: only the loaded record names the locked workspace.
        connection._getSessionRecordForTesting = { id in
            makeTestSession(id: id, workspaceId: "w2", status: .busy)
        }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-a", workspaceId: "w2"))

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "current")
        // Focus (command routing and the stream) stays on the chat on screen,
        // and the locked session never becomes the viewed (seen) one.
        #expect(connection.focusedSessionId == "current")
        #expect(connection.sessionStore.viewingSessionId == "current")
    }

    @Test func cancellingALockOnlyDialogsRevealReturnsFocusToTheVisibleChat() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("current", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "current",
            workspaceId: "w1"
        ))
        let connection = harness.connection("server-a")
        connection.focusSession("current")
        stubLockedWorkspaceOnlyInDialogs(on: connection, harness: harness)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        // The open focused the locked session before its dialogs named the
        // workspace; the cancel hands focus and the stream back.
        harness.expectSessionRoute(serverId: "server-a", sessionId: "current")
        #expect(connection.focusedSessionId == "current")
        #expect(connection.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/current/stream")
    }

    @Test func cancellingALockOnlyDialogsRevealClosesTheLockedStream() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled]
        )
        let connection = harness.connection("server-a")
        #expect(connection.focusedSessionId == nil)
        stubLockedWorkspaceOnlyInDialogs(on: connection, harness: harness)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        // Nothing was focused before: the locked session's focus and stream close.
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(connection.focusedSessionId == nil)
        #expect(connection.focusedSessionStreamURLForTesting == nil)
        #expect(connection.sessionStore.viewingSessionId == nil)
    }

    /// The session's record and timeline do not load; only its pending ask
    /// (from `/dialogs`) names its workspace, `w2`, which is locked.
    private func stubLockedWorkspaceOnlyInDialogs(on connection: ServerConnection, harness: OpenerHarness) {
        connection._connectStreamForTesting = { AsyncStream { _ in } }
        connection._getSessionRecordForTesting = { _ in throw URLError(.timedOut) }
        connection._getSessionDialogsForTesting = { _ in
            APIClient.SessionDialogsResponse(
                dialogs: [
                    ExtensionUIRequest.DialogSnapshot(
                        id: "ask-locked",
                        method: "ask",
                        workspaceId: "w2",
                        questions: [
                            AskQuestion(id: "q1", question: "Answer me", options: [], multiSelect: false),
                        ],
                        allowCustom: true
                    ),
                ],
                serverNow: 1
            )
        }
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-a", workspaceId: "w2"))
    }

    @Test func aReceiptForAnUnreadableServerSurvivesLaunchAndParks() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            unreadableServerIds: ["server-b"],
            launch: false
        )
        let receipt = IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-b",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Write the release notes",
            session: nil
        )
        harness.intentTrigger.enqueue(receipt)

        harness.opener.launchDidFinish()
        await harness.settle()

        // server-b is still paired; only its record could not be read. The
        // receipt and its prompt stay, and the open waits for a later try.
        #expect(harness.intentTrigger.peek()?.unsentPrompt == "Write the release notes")
        #expect(harness.opener._parkedRequestForTesting == .session(SessionOpen(
            serverId: "server-b",
            sessionId: "created",
            workspaceId: "w1",
            origin: .externalURL,
            startedSessionRequestID: receipt.requestID
        )))
        #expect(harness.connection("server-a").extensionToast
            == "Can\u{2019}t read this server\u{2019}s saved pairing right now")

        // The next foreground keeps it parked rather than dropping it as removed.
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.opener._parkedRequestForTesting != nil)
        #expect(harness.intentTrigger.peek() != nil)
    }

    @Test func destinationWorkspaceComesFromLoadedDataNotTheRequestHint() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            authOutcomes: [.cancelled]
        )
        let connection = harness.connection("server-a")
        connection.askRequestStore.set(AskRequest(
            id: "ask-1",
            sessionId: "child",
            questions: [],
            allowCustom: true,
            timeout: nil,
            workspaceId: "w1"
        ), for: "child")
        // The session record cannot load (refresh fails); only the ask names
        // its workspace.
        harness.scopedLock.sessionLookup = { [weak harness] serverId, sessionId in
            harness?.connection(serverId).sessionStore.session(id: sessionId)
        }
        harness.scopedLock.lock(.workspace(serverId: "server-a", workspaceId: "w1"))

        // The request carries a hint for an unlocked workspace.
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            workspaceId: "other",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.coordinator.activeServerId == "server-a")
    }

    // MARK: - Web and system links

    @Test func webLinkFollowsTheBrowserPreference() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        let url = try #require(URL(string: "https://example.com/docs"))

        harness.opener._browserLinkPreferenceForTesting = .inApp
        harness.opener.open(.webLink(url))
        await harness.settle()

        harness.opener._browserLinkPreferenceForTesting = .external
        harness.opener.open(.webLink(url))
        await harness.settle()

        #expect(harness.recorder.browserURLs == [url])
        #expect(harness.recorder.systemURLs == [url])
    }

    @Test func webLinkAndSystemLinkNeverWaitForLaunch() async throws {
        let harness = OpenerHarness(servers: [], launch: false)
        let web = try #require(URL(string: "https://example.com/docs"))
        let mail = try #require(URL(string: "mailto:support@example.com"))
        harness.opener._browserLinkPreferenceForTesting = .external

        harness.opener.open(.webLink(web))
        await harness.settle()
        harness.opener.open(.system(mail))
        await harness.settle()

        #expect(harness.recorder.systemURLs == [web, mail])
        #expect(harness.opener._parkedRequestForTesting == nil)
    }
}

/// `[[id]]` from outside any chat: every paired server's session with that id
/// matches.
private func ambiguousSessionReference(_ sessionId: String) -> ResourceReference {
    ResourceReference(
        target: sessionId,
        sourceServerID: nil,
        workspaceID: nil,
        sourceSessionID: nil,
        fileCandidatePath: nil
    )
}

enum AppLockUnlockOutcome: String, Sendable, CaseIterable {
    case success
    case cancelled
    case backgrounded
}

// MARK: - Fixture

@MainActor
private final class LinkRecorder {
    var browserURLs: [URL] = []
    var systemURLs: [URL] = []
}

@MainActor
private final class StubAuthenticator {
    private var outcomes: [DeviceOwnerAuthentication.Outcome]
    private(set) var prompts = 0
    /// While true a prompt stays up until `answer(_:)`, so a test can change the app under it.
    var holdsPrompts = false
    private var pending: CheckedContinuation<DeviceOwnerAuthentication.Outcome, Never>?

    init(outcomes: [DeviceOwnerAuthentication.Outcome]) {
        self.outcomes = outcomes
    }

    var isAsking: Bool { pending != nil }

    func authenticate() async -> DeviceOwnerAuthentication.Outcome {
        prompts += 1
        if holdsPrompts {
            return await withCheckedContinuation { pending = $0 }
        }
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }

    func answer(_ outcome: DeviceOwnerAuthentication.Outcome) {
        pending?.resume(returning: outcome)
        pending = nil
    }
}

@MainActor
private final class OpenerHarness {
    let serverStore: ServerStore
    let coordinator: ConnectionCoordinator
    let navigation = AppNavigation()
    let composerDraftStore: ComposerDraftStore
    let appLock: AppLockService
    let scopedLock: ScopedLockService
    let intentTrigger: IntentSessionOpenTrigger
    let recorder: LinkRecorder
    let opener: AppOpener
    let authenticator: StubAuthenticator
    var unreachableServers: Set<String> = []
    private var connections: [String: ServerConnection] = [:]
    private let traceRequests = OSAllocatedUnfairLock(initialState: 0)
    /// The fixture's network: every request fails, and the handler ends with the harness.
    private let networkRoutes: TestURLProtocol.RouteScope

    /// Timeline prefetches (`…/trace-page` requests) the fixture's network saw.
    var traceReads: Int { traceRequests.withLock { $0 } }

    init(
        servers: [PairedServer],
        unreadableServerIds: [String] = [],
        appLockTimeout: AppLockTimeout = .off,
        authOutcomes: [DeviceOwnerAuthentication.Outcome] = [.success],
        launch: Bool = true,
        loadsServers: Bool = true
    ) {
        let recorder = LinkRecorder()
        self.recorder = recorder
        let lockDefaults = UserDefaults(suiteName: "AppOpenerTests-lock-\(UUID().uuidString)")!
        AppLockSettings.setTimeout(appLockTimeout, in: lockDefaults)
        let authenticator = StubAuthenticator(outcomes: authOutcomes)
        self.authenticator = authenticator
        let appLock = AppLockService(
            defaults: lockDefaults,
            monotonicNow: { 10_000 },
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in await authenticator.authenticate() },
            didTurnOn: {}
        )
        self.appLock = appLock
        let scopedDefaults = UserDefaults(suiteName: "AppOpenerTests-scoped-\(UUID().uuidString)")!
        scopedLock = ScopedLockService(defaults: scopedDefaults, appLock: appLock, didLock: { _ in })

        // The Keychain may hold servers other suites paired; this fixture's
        // list is read from memory.
        let serverStore = ServerStore(loadServers: {
            .init(records: servers, unreadableIds: unreadableServerIds)
        })
        if loadsServers {
            serverStore.load()
        }
        self.serverStore = serverStore
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        self.coordinator = coordinator
        composerDraftStore = ComposerDraftStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "AppOpenerTests-drafts-\(UUID().uuidString).json"),
            saveDelay: .seconds(60)
        )
        intentTrigger = IntentSessionOpenTrigger(
            defaults: UserDefaults(suiteName: "AppOpenerTests-intent-\(UUID().uuidString)")!,
            promptFileURL: FileManager.default.temporaryDirectory
                .appending(path: "AppOpenerTests-prompt-\(UUID().uuidString).json")
        )

        let opener = AppOpener(
            coordinator: coordinator,
            navigation: navigation,
            composerDraftStore: composerDraftStore,
            appLock: appLock,
            scopedLock: scopedLock,
            intentSessionOpenTrigger: intentTrigger,
            browserPresent: { recorder.browserURLs.append($0) },
            systemOpen: { recorder.systemURLs.append($0) }
        )
        self.opener = opener
        let traceRequests = traceRequests
        networkRoutes = TestURLProtocol.routeScope { request in
            if request.url?.path.hasSuffix("/trace-page") == true {
                traceRequests.withLock { $0 += 1 }
            }
            throw URLError(.notConnectedToInternet)
        }
        opener._serverReadyForTesting = { [weak self] serverId in
            guard let self else { return false }
            guard !self.unreachableServers.contains(serverId) else { return false }
            guard self.serverStore.server(for: serverId) != nil else { return false }
            self.installConnection(for: serverId, activate: true)
            return true
        }
        if !servers.isEmpty {
            installConnection(for: servers[0].id, activate: true)
        }
        // A parked request only runs in a foreground app.
        opener.sceneDidBecomeActive()
        if launch {
            opener.launchDidFinish()
        }
    }

    deinit {
        networkRoutes.end()
    }

    func connection(_ serverId: String) -> ServerConnection {
        installConnection(for: serverId)
    }

    func addSession(_ sessionId: String, parent: String? = nil, workspaceId: String, to serverId: String) {
        var session = makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)
        session.parentSessionId = parent
        connection(serverId).sessionStore.upsert(session)
    }

    func setAskDialog(sessionId: String, on serverId: String) {
        let connection = connection(serverId)
        connection._getSessionDialogsForTesting = { _ in
            APIClient.SessionDialogsResponse(
                dialogs: [
                    ExtensionUIRequest.DialogSnapshot(
                        id: "ask-\(sessionId)",
                        method: "ask",
                        questions: [
                            AskQuestion(id: "q1", question: "Answer me", options: [], multiSelect: false),
                        ],
                        allowCustom: true
                    ),
                ],
                serverNow: 1
            )
        }
    }

    /// `workspaceId` is locked, and sessions are looked up in the fixture's stores.
    func lockWorkspace(_ workspaceId: String, on serverId: String) {
        scopedLock.sessionLookup = { [weak self] serverId, sessionId in
            self?.connection(serverId).sessionStore.session(id: sessionId)
        }
        scopedLock.lock(.workspace(serverId: serverId, workspaceId: workspaceId))
    }

    var stackSessionIds: [String] {
        navigation.workspaceStackRouteElements.compactMap {
            if case .session(let target) = $0 { return target.sessionId }
            return nil
        }
    }

    var lastSessionRoute: WorkspaceSessionNavTarget? {
        guard case .session(let target)? = navigation.workspaceStackRouteElements.last else {
            return nil
        }
        return target
    }

    func expectSessionRoute(
        serverId: String,
        sessionId: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let route = lastSessionRoute
        #expect(route?.serverId == serverId, sourceLocation: sourceLocation)
        #expect(route?.sessionId == sessionId, sourceLocation: sourceLocation)
    }

    func settle() async {
        await opener._waitForOpenToSettleForTesting()
        await opener.invitePairingTask?.value
    }

    /// Seeds the fixture connection. Seeding never changes the active server:
    /// only a successful switch (or the first paired server) does.
    @discardableResult
    private func installConnection(
        for serverId: String,
        activate: Bool = false
    ) -> ServerConnection {
        let connection: ServerConnection
        if let existing = connections[serverId] {
            connection = existing
        } else {
            connection = ServerConnection()
            if let server = serverStore.server(for: serverId) {
                connection.configure(credentials: server.credentials)
            }
            connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
            // The network is down for every fixture, so the timeline prefetch
            // fails without touching the session row a test seeded.
            connection.setAPIClientForTesting(
                makeTestURLProtocolClient(host: "\(serverId).test", scheme: "https")
            )
            connections[serverId] = connection
        }
        // Every fixture is reachable to lookups; seeding never changes which
        // one is active.
        let active = coordinator.activeServerId
        coordinator.installPreviewConnection(connection, serverId: serverId)
        if !activate, let active, active != serverId, let activeConnection = connections[active] {
            coordinator.installPreviewConnection(activeConnection, serverId: active)
        }
        return connection
    }
}

private func makeServer(_ id: String) -> PairedServer {
    let credentials = ServerCredentials(
        host: "\(id).test",
        port: 7749,
        token: "sk_test",
        name: id,
        scheme: .https,
        serverFingerprint: id
    )
    guard let server = PairedServer(from: credentials, sortOrder: 0) else {
        preconditionFailure("Failed to create PairedServer for test")
    }
    return server
}
