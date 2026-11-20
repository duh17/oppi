import SwiftUI
import Testing
@testable import Oppi

private actor ResourceReferenceAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("SceneNavigation shell routing")
@MainActor
struct SceneNavigationShellRoutingTests {
    @Test func pairedLaunchRevealNeverShowsOnboarding() {
        let navigation = SceneNavigation()
        navigation.app.showOnboarding = true

        navigation.app.revealPairedServerShell()

        #expect(navigation.app.launchPhase == .ready)
        #expect(!navigation.app.showOnboarding)
    }

    @Test func pairedLaunchRevealsLocalStateBeforeTransportPreparation() async {
        var events: [String] = []

        let result = await PairedLaunchSequence.revealThenPrepare(
            loadLocalState: { events.append("cache") },
            reveal: { events.append("reveal") },
            prepare: {
                events.append("transport")
                return "ready"
            }
        )

        #expect(events == ["cache", "reveal", "transport"])
        #expect(result == "ready")
    }

    @Test func launchShowsOnboardingOnlyAfterAnEmptySuccessfulLoad() {
        #expect(AppLaunchPairingPolicy.route(loadState: .loaded, pairedServerCount: 0) == .onboarding)
        #expect(AppLaunchPairingPolicy.route(loadState: .unavailable, pairedServerCount: 0) == .keepResolving)
        #expect(AppLaunchPairingPolicy.route(loadState: .unloaded, pairedServerCount: 0) == .keepResolving)
        #expect(AppLaunchPairingPolicy.route(loadState: .loaded, pairedServerCount: 2) == .pairedShell)
    }

    @Test func inviteClaimPredicateClaimsOnlyConnectAndPairRoutes() throws {
        let claimed = [
            "oppi://connect?v=3&invite=x",
            "oppi://pair?v=3&invite=x",
            "OPPI://CONNECT?v=3",
            "oppi:/connect?v=3",
            "oppi:/pair?v=3",
        ]
        let declined = [
            "oppi://session/a/b",
            "oppi://session/child-1",
            "oppi://workspace?path=/tmp/project",
            "https://example.com/connect",
        ]

        for raw in claimed {
            let url = testUnwrap(URL(string: raw))
            #expect(InAppInviteLink.claims(url), "\(raw)")
        }
        for raw in declined {
            let url = testUnwrap(URL(string: raw))
            #expect(!InAppInviteLink.claims(url), "\(raw)")
        }
    }

    @Test func inAppSessionServerResolutionRequiresSourceOrGlobalUniqueness() {
        #expect(InAppSessionServerResolution.resolve(
            sourceServerID: "server-b",
            sourceServerHasMatch: true,
            matchingServerIDs: ["server-a", "server-b"]
        ) == "server-b")
        #expect(InAppSessionServerResolution.resolve(
            sourceServerID: "server-c",
            sourceServerHasMatch: false,
            matchingServerIDs: ["server-a", "server-b"]
        ) == nil)
        #expect(InAppSessionServerResolution.resolve(
            sourceServerID: "stale-server",
            sourceServerHasMatch: false,
            matchingServerIDs: ["server-a"]
        ) == nil)
        #expect(InAppSessionServerResolution.resolve(
            sourceServerID: nil,
            sourceServerHasMatch: false,
            matchingServerIDs: ["server-a"]
        ) == "server-a")
        #expect(InAppSessionServerResolution.resolve(
            sourceServerID: nil,
            sourceServerHasMatch: false,
            matchingServerIDs: ["server-a", "server-b"]
        ) == nil)
    }

    @Test func setWorkspaceSessionPathReplacesExistingStackInOneAssignment() {
        let navigation = SceneNavigation()
        navigation.openWorkspaceUtility(.appSettings)
        navigation.openWorkspaceUtility(.manageServers)

        navigation.setWorkspaceSessionPath(serverId: "server-1", sessionId: "session-1")

        #expect(navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func externalSessionDeepLinkPolicyReplacesKnownAndRootsUnknownTargets() {
        let navigation = SceneNavigation()
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let inAppTarget = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "in-app-target",
            workspaceId: "workspace-1"
        )
        navigation.openWorkspaceSession(source)

        navigation.openSession(inAppTarget, source: .inAppHyperlink)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "in-app-target")

        navigation.openSession(
            WorkspaceSessionNavTarget(
                serverId: "server-1",
                sessionId: "external-target",
                workspaceId: "workspace-1"
            ),
            source: .externalURL
        )

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "external-target")

        for presentation in [
            WorkspaceNavigationPresentation.stack,
            WorkspaceNavigationPresentation.split,
        ] {
            let missingTargetNavigation = SceneNavigation()
            missingTargetNavigation.setWorkspaceNavigationPresentation(presentation)
            missingTargetNavigation.openWorkspaceSession(.init(
                serverId: "server-1",
                sessionId: "visible-session",
                workspaceId: "workspace-1"
            ))
            if presentation == .split {
                missingTargetNavigation.openReferencedSession(.init(
                    serverId: "server-1",
                    sessionId: "pushed-session",
                    workspaceId: "workspace-1"
                ))
            }

            missingTargetNavigation.selectedTab = .workspaces
            missingTargetNavigation.clearWorkspaceSelections()

            #expect(missingTargetNavigation.selectedTab == .workspaces)
            #expect(missingTargetNavigation.workspaceStackRouteElements.isEmpty)
            #expect(missingTargetNavigation.selectedWorkspaceFilter == nil)
            #expect(missingTargetNavigation.splitDetailColumn.rootIndex == nil)
            #expect(missingTargetNavigation.splitDetailColumn.pushed.isEmpty)
            #expect(missingTargetNavigation.workspaceStackDiagnosticContext == .inboxAll)
            #expect(missingTargetNavigation.visibleSplitDiagnosticContext.screen == "workspace_split_inbox_all")
        }
    }

    @Test func referencedSessionAppendsToCompactChatHistoryAndSelfLinkIsNoOp() {
        let navigation = SceneNavigation()
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let target = WorkspaceSessionNavTarget(
            serverId: "server-2",
            sessionId: "target",
            workspaceId: "workspace-2"
        )
        navigation.openWorkspaceSession(source)

        navigation.openReferencedSession(target)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "target")
        navigation.openReferencedSession(target)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "source")
    }

    /// A refused lock takes the session's route off the compact stack, leaves every other screen, and
    /// says whether the session was the one on top. A session of another server with the same id is not it.
    @Test func removingASessionRouteFromTheStackLeavesOtherScreensAndReportsWhetherItWasVisible() {
        let navigation = SceneNavigation()
        let locked = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "locked", workspaceId: "w1")
        let other = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "w1")
        navigation.openWorkspaceSession(locked)
        navigation.openReferencedSession(other)

        #expect(!navigation.removeSessionRoute(serverId: "server-2", sessionId: "locked"))
        #expect(navigation.workspaceStackRouteElements == [.session(locked), .session(other)])

        #expect(!navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"), "Another screen was on top")
        #expect(navigation.workspaceStackRouteElements == [.session(other)])

        #expect(navigation.removeSessionRoute(serverId: "server-1", sessionId: "other"), "It was on top")
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    /// A reader opened from the chat has its lock origin fixed at the workspace the chat had then, so it
    /// goes with the chat. Another session's chat above is not under this lock: it and its screens stay.
    @Test func removingASessionRouteAlsoDropsTheReadersOpenedFromItInTheStack() {
        let navigation = SceneNavigation()
        let locked = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "locked", workspaceId: "w1")
        let other = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "w1")
        let reader = ChatReaderNavTarget(id: UUID())
        let otherReader = ChatReaderNavTarget(id: UUID())
        navigation.openWorkspaceSession(locked)
        navigation.openChatReader(reader)
        navigation.openReferencedSession(other)
        navigation.openChatReader(otherReader)

        #expect(!navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"), "Another chat was on top")
        #expect(navigation.workspaceStackRouteElements == [.session(other), .chatReader(otherReader)])

        navigation.openWorkspaceSession(locked)
        navigation.openChatReader(reader)
        #expect(navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"), "The reader was on top")
        #expect(navigation.workspaceStackRouteElements == [.session(other), .chatReader(otherReader)])
    }

    @Test func removingASessionRouteAlsoDropsTheReadersOpenedFromItInTheSplitDetail() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        let root = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "root", workspaceId: "w1")
        let locked = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "locked", workspaceId: "w1")
        let other = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "w1")
        let reader = ChatReaderNavTarget(id: UUID())
        navigation.openWorkspaceSession(root)
        navigation.openReferencedSession(locked)
        navigation.openChatReader(reader)
        navigation.openReferencedSession(other)
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(root), .session(locked), .chatReader(reader), .session(other)])

        #expect(!navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"))
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(root), .session(other)])

        navigation.openChatReader(reader)
        #expect(navigation.removeSessionRoute(serverId: "server-1", sessionId: "other"), "The reader was on top")
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(root)])
    }

    /// The split shows the same chats above its place as the compact stack does: removing one leaves the
    /// place, and another session's chat pushed over it stays.
    @Test func removingASplitChatLeavesItsPlaceAndAnotherSessionsChat() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        let locked = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "locked", workspaceId: "w1")
        let other = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "w1")
        navigation.openWorkspaceSession(locked)
        #expect(navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"))
        #expect(navigation.splitDetailColumn.routes == [.inbox])
        #expect(navigation.showsAllSessionsRoot)

        navigation.openWorkspaceSession(locked)
        navigation.openReferencedSession(other)
        #expect(!navigation.removeSessionRoute(serverId: "server-1", sessionId: "locked"), "Another screen was on top")
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(other)])
    }

    @Test func referencedSessionPushesFromSplitChatAndSelfLinkIsNoOp() {
        let navigation = SceneNavigation()
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let target = WorkspaceSessionNavTarget(
            serverId: "server-2",
            sessionId: "target",
            workspaceId: "workspace-2"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(source)

        navigation.openReferencedSession(target)

        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(source), .session(target)])
        #expect(navigation.visibleSplitDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "chat",
            sessionId: "target",
            workspaceId: "workspace-2"
        ))
        navigation.openReferencedSession(target)
        #expect(navigation.splitDetailColumn.pushed.count == 2)
        navigation.popShownStack(toDepth: navigation.splitDetailColumn.pushed.count - 1)
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(source)])
        #expect(navigation.visibleSplitDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "chat",
            sessionId: "source",
            workspaceId: "workspace-1"
        ))
    }

    @Test func referencedWorkspaceFilePreservesChatBackStackAcrossPresentations() {
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "notes/linked.md"
        )

        for presentation in [WorkspaceNavigationPresentation.stack, .split] {
            let navigation = SceneNavigation()
            navigation.setWorkspaceNavigationPresentation(presentation)
            navigation.openWorkspaceSession(source)

            navigation.openReferencedWorkspaceLinkedFile(
                file,
                workspace: workspace,
                sourceSession: source
            )

            switch presentation {
            case .stack:
                #expect(navigation.workspaceStackRouteElements.count == 2)
                #expect(navigation.selectedWorkspaceFilter == nil)
                navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
                #expect(navigation.workspaceStackRouteElements.count == 1)
                #expect(navigation.selectedWorkspaceFilter == nil)
            case .split:
                #expect(navigation.splitDetailColumn.routes == [.inbox, .session(source), .linkedFile(file)])
                navigation.popShownStack(toDepth: navigation.splitDetailColumn.pushed.count - 1)
                #expect(navigation.splitDetailColumn.routes == [.inbox, .session(source)])
            }
        }
    }

    @Test func referencedWorkspaceFileFallsBackToExplicitWorkspaceNavigationWhenSourceIsNotVisible() {
        let navigation = SceneNavigation()
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "notes/linked.md"
        )

        navigation.openReferencedWorkspaceLinkedFile(
            file,
            workspace: workspace,
            sourceSession: source
        )

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == workspace)
    }

    @Test func visibleSplitDiagnosticContextTracksNonSessionPathTop() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.agents)
        navigation.openServerResourceDetail(.init(
            serverId: "server-1",
            kind: .extension,
            resourceId: "extension-1"
        ))

        #expect(navigation.visibleSplitDiagnosticContext.screen == "server_extension_detail")
        #expect(navigation.visibleSplitDiagnosticContext.sessionId == nil)
        #expect(navigation.visibleSplitDiagnosticContext.workspaceId == nil)

        navigation.popShownStack(toDepth: navigation.splitDetailColumn.pushed.count - 1)
        #expect(navigation.visibleSplitDiagnosticContext.screen == "utility_agents")
    }

    @Test func referencedSessionChainSurvivesCompactToSplitToCompactTransition() {
        let navigation = SceneNavigation()
        let source = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "source",
            workspaceId: "workspace-1"
        )
        let target = WorkspaceSessionNavTarget(
            serverId: "server-2",
            sessionId: "target",
            workspaceId: "workspace-2"
        )
        navigation.openWorkspaceSession(source)
        navigation.openReferencedSession(target)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(source), .session(target)])

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "target")
        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "source")
    }

    @Test func supersededRequestDuringPreparationCannotActivateServerOrNavigate() async {
        let preparationGate = ResourceReferenceAsyncGate()
        let navigation = SceneNavigation()
        let newerSession = WorkspaceSessionNavTarget(
            serverId: "server-newer",
            sessionId: "newer",
            workspaceId: "workspace-newer"
        )
        let staleSession = WorkspaceSessionNavTarget(
            serverId: "server-stale",
            sessionId: "stale",
            workspaceId: "workspace-stale"
        )
        navigation.openWorkspaceSession(newerSession)
        var activeServerID = "server-newer"

        var superseded = false
        let activation = Task {
            _ = await PreparedServerActivation.run(
                prepare: {
                    await preparationGate.wait()
                    return "server-stale"
                },
                shouldActivate: { !superseded },
                activate: { serverID in
                    activeServerID = serverID
                    navigation.openReferencedSession(staleSession)
                }
            )
        }
        await Task.yield()

        superseded = true
        await preparationGate.open()
        await activation.value

        #expect(activeServerID == "server-newer")
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "newer")
    }

    @Test func workspaceLessCandidateCollectionResolvesKnownSessionWithoutFileLookup() {
        let reference = ResourceReference(
            target: "RV97TbYj",
            sourceServerID: "server-source",
            workspaceID: nil,
            sourceSessionID: "session-source",
            fileCandidatePath: nil
        )
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-target",
            sessionID: "RV97TbYj",
            workspaceID: nil,
            displayName: "Known session",
            workspaceName: nil,
            serverName: "Mac"
        ))

        #expect(ResourceReferenceCandidateCollector.resolve(
            reference,
            sessionMatches: [session],
            fileLookup: .notApplicable
        ) == .resolution(.resolved(session)))
    }

    @Test func aShellChangeKeepsTheOneStackAndShowsItInTheDetailColumn() {
        let navigation = SceneNavigation()
        navigation.openWorkspaceUtility(.appSettings)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .split)
        #expect(navigation.workspaceStackRouteElements == [.utility(.appSettings)])
        #expect(navigation.splitDetailColumn.routes == [.utility(.appSettings)])
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func openWorkspacePushesInboxInStackPresentation() {
        let navigation = SceneNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.openWorkspaceUtility(.appSettings)

        navigation.openWorkspace(target)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == target)
    }

    @Test func openWorkspaceUsesSplitSelectionInSplitPresentation() {
        let navigation = SceneNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspace(target)
        #expect(navigation.selectedWorkspaceFilter == target)
        #expect(navigation.splitDetailColumn.rootIndex == nil)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func showAllWorkspaceSessionsPopsWorkspaceInbox() {
        let navigation = SceneNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.openWorkspace(target)

        navigation.showAllWorkspaceSessions()

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func leaveDeletedWorkspaceReturnsSelectedInboxToAllSessions() {
        let navigation = SceneNavigation()
        let target = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1", name: "Notes")
        )
        navigation.openWorkspace(target)

        navigation.leaveDeletedWorkspace(serverId: "server-1", workspaceId: "workspace-1")

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func leaveDeletedWorkspaceMatchesSelectionByIdentityWhenNameChanged() {
        let navigation = SceneNavigation()
        let selected = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1", name: "Notes")
        )
        navigation.openWorkspace(selected)

        navigation.leaveDeletedWorkspace(serverId: "server-1", workspaceId: "workspace-1")

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func leaveDeletedWorkspaceLeavesUnselectedWorkspaceOnManagePath() {
        let navigation = SceneNavigation()
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        let selected = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-keep", name: "Keep")
        )
        navigation.openWorkspace(selected)
        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-1")
        let pathCount = navigation.workspaceStackRouteElements.count

        navigation.leaveDeletedWorkspace(serverId: "server-1", workspaceId: "workspace-delete")

        #expect(navigation.selectedWorkspaceFilter == selected)
        #expect(navigation.workspaceStackRouteElements.count == pathCount)
        #expect(navigation.visibleHostSwitcherDestination == .serverSettings)
    }

    @Test func leaveDeletedWorkspaceNoopsWhenNothingIsSelected() {
        let navigation = SceneNavigation()
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-1")
        let pathCount = navigation.workspaceStackRouteElements.count

        navigation.leaveDeletedWorkspace(serverId: "server-1", workspaceId: "workspace-1")

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspaceStackRouteElements.count == pathCount)
        #expect(navigation.visibleHostSwitcherDestination == .serverSettings)
    }

    @Test func leaveDeletedWorkspaceClearsSplitSelection() {
        let navigation = SceneNavigation()
        let target = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(target)

        navigation.leaveDeletedWorkspace(serverId: "server-1", workspaceId: "workspace-1")

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitDetailColumn.rootIndex == nil)
    }

    @Test func sessionOpenedFromWorkspaceBuildsAllWorkspaceChatHierarchy() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)

        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"),
            workspace: workspaceTarget
        )

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
        #expect(navigation.selectedWorkspaceFilter == nil)
    }

    @Test func sessionOpenedFromAllSessionsKeepsAllSessionsAsBackStop() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )

        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
        #expect(navigation.selectedWorkspaceFilter == nil)
    }

    @Test func stackDiagnosticContextTracksVisibleDestinationAcrossBackNavigation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"),
            workspace: workspaceTarget
        )

        #expect(navigation.workspaceStackDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "chat",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        ))

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "workspace_inbox_filtered",
            sessionId: nil,
            workspaceId: "workspace-1"
        ))

        navigation.openWorkspaceUtility(.appSettings)
        #expect(navigation.workspaceStackDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "utility_app_settings",
            sessionId: nil,
            workspaceId: nil
        ))
    }

    /// Back means back: content opened from a place, or from other content, is pushed over the
    /// screen it was opened from in both shells, and Back returns to that screen, also when the
    /// window changed shell in between (a rotation on the iPad mini).
    @Test func backReturnsToTheScreenContentWasOpenedFromInBothShellsAndAcrossARotation() {
        let workspace = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let chat = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "chat", workspaceId: "workspace-1")
        let other = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "other", workspaceId: "workspace-1")
        let folder = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "notes/")
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: "server-1", workspaceId: "workspace-1", path: "notes/a.md")
        typealias Row = (
            journey: String, from: ShellRoute, start: (SceneNavigation) -> Void,
            open: (SceneNavigation) -> Void, opened: ShellRoute
        )
        let rows: [Row] = [
            ("All Sessions → chat", .inbox, { _ in }, { $0.openWorkspaceSession(chat) }, .session(chat)),
            ("a workspace's list → chat", .workspace(workspace), { $0.openPlace(.sessions(workspace)) },
             { $0.openWorkspaceSession(chat, workspace: workspace) }, .session(chat)),
            ("Pinned → chat", .utility(.pinned), { $0.openPlace(.utility(.pinned)) },
             { $0.openReferencedSession(chat) }, .session(chat)),
            ("Agents → chat", .utility(.agents), { $0.openPlace(.utility(.agents)) },
             { $0.openWorkspaceSession(chat) }, .session(chat)),
            ("Schedules → a run's chat", .utility(.schedules), { $0.openPlace(.utility(.schedules)) },
             { $0.openWorkspaceSession(chat) }, .session(chat)),
            ("Pinned → folder", .utility(.pinned), { $0.openPlace(.utility(.pinned)) },
             { $0.openWorkspaceFileBrowser(folder) }, .fileBrowser(folder)),
            ("Pinned → file", .utility(.pinned), { $0.openPlace(.utility(.pinned)) },
             { $0.openWorkspaceLinkedFile(file) }, .linkedFile(file)),
            ("a workspace's list → Files", .workspace(workspace), { $0.openPlace(.sessions(workspace)) },
             { $0.openWorkspaceFileBrowser(folder, workspace: workspace) }, .fileBrowser(folder)),
            ("a workspace's list → Workspace Settings", .workspace(workspace), { $0.openPlace(.sessions(workspace)) },
             { $0.openWorkspaceConfiguration(workspace) }, .workspaceConfiguration(workspace)),
            ("a chat → a session link", .session(chat), { $0.openWorkspaceSession(chat) },
             { $0.openReferencedSession(other) }, .session(other)),
            ("a chat → a file link", .session(chat), { $0.openWorkspaceSession(chat) },
             { $0.openReferencedWorkspaceLinkedFile(file, workspace: workspace, sourceSession: chat) }, .linkedFile(file)),
        ]
        for row in rows {
            for opening in [WorkspaceNavigationPresentation.stack, .split] {
                for back in [WorkspaceNavigationPresentation.stack, .split] {
                    let navigation = readyNavigation()
                    navigation.setWorkspaceNavigationPresentation(opening)
                    row.start(navigation)
                    row.open(navigation)
                    navigation.setWorkspaceNavigationPresentation(back)
                    let journey = "\(row.journey), opened in \(opening), Back in \(back)"
                    #expect(Self.shown(navigation).last == row.opened, "\(journey): \(Self.shown(navigation))")
                    navigation.popShownStack(toDepth: Self.shown(navigation).count - 2)
                    #expect(Self.shown(navigation).last == row.from, "\(journey): \(Self.shown(navigation))")
                }
            }
        }
    }

    /// What a shell shows, root first: the compact stack above All Sessions, or the split's detail column.
    private static func shown(_ navigation: SceneNavigation) -> [ShellRoute] {
        navigation.workspaceNavigationPresentation == .split
            ? navigation.splitDetailColumn.routes
            : [.inbox] + navigation.workspaceStackRouteElements.map(ShellRoute.init)
    }

    @Test func controlSessionNeverReceivesWorkspaceFallback() {
        let target = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "control-1",
            routeScope: .control
        )

        let resolved = target.withWorkspaceIdIfMissing("workspace-1")

        #expect(resolved.routeScope == .control)
        #expect(resolved.workspaceId == nil)
    }

    @Test func splitUtilityOwnsPushedControlChatAndBackStack() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.agents)

        navigation.openWorkspaceSession(.init(
            serverId: "server-1",
            sessionId: "control-1",
            routeScope: .control
        ))

        #expect(navigation.splitDetailColumn.root == .utility(.agents))
        #expect(navigation.splitDetailColumn.pushed.count == 1)
        #expect(navigation.splitColumnVisibility == .detailOnly)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "control-1")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailColumn.root == .utility(.agents))
        #expect(navigation.splitDetailColumn.pushed.count == 1)
    }

    @Test func splitSidebarFollowsTheTopScreenAndThePersonsChoiceHoldsUntilTheyNavigate() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.schedules)
        #expect(navigation.splitColumnVisibility == .all)

        navigation.openWorkspaceSession(.init(serverId: "server-1", sessionId: "run-1"))
        #expect(navigation.splitDetailColumn.pushed.count == 1)
        #expect(navigation.splitColumnVisibility == .detailOnly, "A chat pushed over Schedules hides the sidebar")

        navigation.toggleSplitSidebar()
        #expect(navigation.splitColumnVisibility == .all, "The person's choice wins over the chat's")

        navigation.popShownStack(toDepth: 0)
        #expect(navigation.splitColumnVisibility == .all, "Back to Schedules shows the sidebar")

        navigation.toggleSplitSidebar()
        #expect(navigation.splitColumnVisibility == .detailOnly)
        navigation.openWorkspaceSession(.init(serverId: "server-1", sessionId: "run-2"))
        navigation.popShownStack(toDepth: 0)
        #expect(navigation.splitColumnVisibility == .all, "Navigating drops the choice; Back shows the sidebar again")

        let browser = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "")
        navigation.openWorkspaceFileBrowser(browser)
        navigation.toggleSplitSidebar()
        navigation.recordFileBrowserColumn(
            serverId: "server-1",
            scope: .workspace(workspaceId: "workspace-1", worktreeId: nil),
            routePath: "",
            directoryPath: "src/",
            selectedFile: nil
        )
        #expect(navigation.splitColumnVisibility == .all, "A column drill inside the browser is no navigation")

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.splitColumnVisibility == .automatic)
        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitColumnVisibility == .detailOnly, "A change of shell starts from the screen")
    }

    @Test func openSessionPreservesWorkspaceHintFromWorkspaceTarget() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        #expect(navigation.splitDetailColumn.routes.last == .session(
            WorkspaceSessionNavTarget(
                serverId: "server-1",
                sessionId: "session-1",
                workspaceId: "workspace-1"
            )
        ))
    }

    @Test func workspaceSelectionRestoresSessionLayerVisibility() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspace(workspaceTarget)

        #expect(navigation.splitColumnVisibility == .all)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
        #expect(navigation.splitDetailColumn.rootIndex == nil)
    }

    @Test func sessionSelectionPreservesSplitColumnVisibility() {
        let navigation = SceneNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspaceSession(sessionTarget)

        #expect(navigation.splitColumnVisibility == .detailOnly)
        #expect(navigation.splitDetailColumn.routes == [.inbox, .session(sessionTarget)])
    }

    @Test func columnDrillSurvivesStackToSplitSwap() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let rootTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "")
        let selected = FileBrowserSelection(path: "src/App.swift", name: "App.swift", size: 4)
        navigation.openWorkspaceFileBrowser(rootTarget, workspace: workspaceTarget)
        navigation.recordFileBrowserColumn(
            serverId: "server-1",
            scope: .workspace(workspaceId: "workspace-1", worktreeId: nil),
            routePath: "",
            directoryPath: "src/",
            selectedFile: selected
        )

        navigation.setWorkspaceNavigationPresentation(.split)

        guard case .fileBrowser(let restored) = navigation.splitDetailColumn.routes.last else {
            Issue.record("file browser was not restored")
            return
        }
        #expect(restored.path.isEmpty)
        #expect(restored.columnDirectoryPath == "src/")
        #expect(restored.columnSelectedFile == selected)
    }

    @Test func linkedFileTargetCarriesLineAnchorThroughNavigation() throws {
        let anchor = try #require(SourceLineAnchor.parse("#L12-L18"))
        let target = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "Sources/App.swift",
            lineAnchor: anchor
        )
        let navigation = SceneNavigation()
        navigation.openWorkspaceLinkedFile(target)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.workspaceId == "workspace-1")
        #expect(target.lineAnchor == anchor)

        let differentAnchor = try #require(SourceLineAnchor.parse("#L13-L18"))
        let differentTarget = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "Sources/App.swift",
            lineAnchor: differentAnchor
        )
        #expect(target != differentTarget)
    }

    @Test func linkedFileSplitSelectionPreservesLineAnchorThroughProductionRoute() throws {
        let anchor = try #require(SourceLineAnchor.parse("#L12-L18"))
        let target = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "Sources/App.swift",
            lineAnchor: anchor
        )
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceLinkedFile(target)

        #expect(navigation.splitDetailColumn.routes.last == .linkedFile(target))

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func linkedFileAppendsInStackPresentationToPreserveBackNavigation() {
        let navigation = SceneNavigation()
        let firstTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/first.md", fileName: "first.md")
        )
        let secondTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )

        navigation.openWorkspaceLinkedFile(firstTarget)
        navigation.openWorkspaceLinkedFile(secondTarget)

        #expect(navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func linkedFileOpenedFromSessionPreservesSessionBackNavigation() {
        let navigation = SceneNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        let fileTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )

        navigation.openWorkspaceSession(sessionTarget)
        navigation.openWorkspaceLinkedFile(fileTarget)

        #expect(navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func linkedFileOpenedFromSplitSessionSurvivesCompactRotation() {
        let navigation = SceneNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        let fileTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceSession(sessionTarget)
        navigation.openWorkspaceLinkedFile(fileTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func linkedFileChainOpenedFromSplitFileSurvivesCompactRotation() {
        let navigation = SceneNavigation()
        let firstTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/first.md", fileName: "first.md")
        )
        let secondTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceLinkedFile(firstTarget)
        navigation.openWorkspaceLinkedFile(secondTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func splitFileBrowserDirectoryDrillSurvivesCompactRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let rootTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "")
        let childTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "notes/")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspaceTarget)

        navigation.openWorkspaceFileBrowser(rootTarget, workspace: workspaceTarget)
        navigation.pushWorkspaceFileBrowser(childTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements == [.workspace(workspaceTarget), .fileBrowser(rootTarget), .fileBrowser(childTarget)])
    }

    @Test func splitAllSessionsSessionKeepsAllSessionsOnCompactRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        #expect(navigation.selectedWorkspaceFilter == nil)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)
    }

    @Test func splitWorkspaceSessionPreservesBothBackLayersOnCompactRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
    }

    @Test func stackWorkspaceSessionSurvivesRegularWidthRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
        #expect(navigation.splitDetailColumn.routes == [.workspace(workspaceTarget), .session(
            WorkspaceSessionNavTarget(
                serverId: "server-1",
                sessionId: "session-1",
                workspaceId: "workspace-1"
            )
        )])
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func stackFileBrowserDrillSurvivesRegularWidthRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let rootTarget = FileBrowserNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: ""
        )
        let childTarget = FileBrowserNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "notes/"
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceFileBrowser(rootTarget, workspace: workspaceTarget)
        navigation.pushWorkspaceFileBrowser(childTarget)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
        #expect(navigation.splitDetailColumn.routes == [.workspace(workspaceTarget), .fileBrowser(rootTarget), .fileBrowser(childTarget)])
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func stackBackBeforeRegularWidthRotationKeepsWorkspaceDetail() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"),
            workspace: workspaceTarget
        )
        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
        #expect(navigation.splitDetailColumn.rootIndex == nil)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func splitSystemBackBeforeCompactRotationDropsPoppedLinkedFile() {
        let navigation = SceneNavigation()
        let firstTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/first.md", fileName: "first.md")
        )
        let secondTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceLinkedFile(firstTarget)
        navigation.openWorkspaceLinkedFile(secondTarget)
        navigation.popShownStack(toDepth: navigation.splitDetailColumn.pushed.count - 1)
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func exactDirectoryLookupPreservesPresentAbsentAndTruncatedSemantics() {
        let presentEntry = FileEntry(
            name: "RV97TbYj.md",
            type: .file,
            size: 10,
            modifiedAt: 0,
            path: "notes/RV97TbYj.md"
        )
        let otherEntry = FileEntry(
            name: "other.md",
            type: .file,
            size: 10,
            modifiedAt: 0,
            path: "notes/other.md"
        )

        #expect(ResourceFileCandidatePolicy.directoryResult(
            fileName: "RV97TbYj.md",
            entries: [presentEntry, otherEntry],
            truncated: true
        ) == true)
        #expect(ResourceFileCandidatePolicy.directoryResult(
            fileName: "RV97TbYj.md",
            entries: [otherEntry],
            truncated: false
        ) == false)
        #expect(ResourceFileCandidatePolicy.directoryResult(
            fileName: "RV97TbYj.md",
            entries: [otherEntry],
            truncated: true
        ) == nil)
    }

    @Test func givenWorkspaceFileInsideHostMountWhenResolvingThenItOpensThatWorkspaceFile() {
        let workspace = makeTestWorkspace(id: "workspace-1", hostMount: "~/workspace/oppi")
        let payload = FileLinkPayload(
            workspaceID: "workspace-1",
            filePath: NSString(string: "~/workspace/oppi/server/src/server.ts").expandingTildeInPath,
            originalURL: URL(string: "file:///Users/example/workspace/oppi/server/src/server.ts")!
        )

        let resolved = FileLinkOpenPolicy.resolve(
            payload: payload,
            workspacesByServer: ["server-1": [workspace]]
        )

        #expect(resolved?.serverId == "server-1")
        #expect(resolved?.workspace.id == "workspace-1")
        #expect(resolved?.relativePath == "server/src/server.ts")
        #expect(resolved?.fileName == "server.ts")
    }

    @Test func givenWorkspaceRelativeFileWhenResolvingThenItOpensThatWorkspaceFile() throws {
        let workspace = makeTestWorkspace(id: "workspace-1", hostMount: "~/workspace/oppi")
        let originalURL = try #require(ResourceReferenceURL.make(ResourceReference(
            target: "notes/sessions/oppi-jZhDRKeV",
            sourceServerID: "server-1",
            workspaceID: "workspace-1",
            sourceSessionID: "session-source",
            fileCandidatePath: "notes/sessions/oppi-jZhDRKeV.md"
        )))
        let payload = FileLinkPayload(
            workspaceID: "workspace-1",
            filePath: "notes/sessions/oppi-jZhDRKeV.md",
            originalURL: originalURL
        )

        let resolved = FileLinkOpenPolicy.resolve(
            payload: payload,
            workspacesByServer: ["server-1": [workspace]]
        )

        #expect(resolved?.serverId == "server-1")
        #expect(resolved?.workspace.id == "workspace-1")
        #expect(resolved?.relativePath == "notes/sessions/oppi-jZhDRKeV.md")
        #expect(resolved?.fileName == "oppi-jZhDRKeV.md")
    }

    @Test func givenWorkspaceFileOutsideHostMountWhenResolvingThenItOpensAsHostFile() {
        let workspace = makeTestWorkspace(id: "workspace-1", hostMount: "~/workspace/oppi")
        let payload = FileLinkPayload(
            workspaceID: "workspace-1",
            filePath: "/tmp/server.ts",
            originalURL: URL(string: "file:///tmp/server.ts")!
        )

        let resolved = FileLinkOpenPolicy.resolve(
            payload: payload,
            workspacesByServer: ["server-1": [workspace]]
        )

        #expect(resolved?.serverId == "server-1")
        #expect(resolved?.workspace.id == "workspace-1")
        #expect(resolved?.kind == .hostFile)
        #expect(resolved?.path == "/tmp/server.ts")
        #expect(resolved?.fileName == "server.ts")
    }

    @Test func hostHTMLAndSVGStayOnStringFetchViewer() {
        #expect(HostFilePreviewPolicy.usesStringFetchViewer(for: "/tmp/report.html"))
        #expect(HostFilePreviewPolicy.webViewLoadMode(for: "/tmp/logo.svg") == .htmlString)
        #expect(HostFilePreviewPolicy.webViewLoadMode(for: "/tmp/notes.md") == .none)
    }

    @Test func hostFileOpenPushesViewerWithoutSwitchingWorkspace() {
        let navigation = SceneNavigation()
        let sourceWorkspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(
            serverId: "server-1",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )
        let hostFile = WorkspaceLinkedFileNavTarget.hostFile(
            serverId: "server-1",
            workspaceId: "",
            path: "/tmp/oppi-debug.log"
        )

        navigation.openWorkspace(sourceWorkspace)
        navigation.openWorkspaceSession(sessionTarget, workspace: sourceWorkspace)
        navigation.openWorkspaceLinkedFile(hostFile)

        #expect(navigation.workspaceStackRouteElements.count == 3)
        #expect(navigation.selectedWorkspaceFilter == sourceWorkspace)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "linked_file")
        #expect(navigation.workspaceStackDiagnosticContext.workspaceId?.isEmpty != false)
    }

    @Test func utilityUsesSplitDetailSelectionInSplitPresentation() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceUtility(.appSettings)
        #expect(navigation.splitDetailColumn.root == .utility(.appSettings))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func agentAndScheduleUtilitiesAreReleaseEnabledAndAppendToStackPath() {
        let navigation = SceneNavigation()

        navigation.openWorkspaceUtility(.agents)

        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_agents")

        navigation.openWorkspaceUtility(.schedules)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_schedules")
    }

    @Test func visibleUtilitiesStillAppendToStackPath() {
        let navigation = SceneNavigation()

        navigation.openWorkspaceUtility(.manageServers)
        navigation.openWorkspaceUtility(.appSettings)

        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspaceStackRouteElements.count == 2)
    }

    @Test func agentAndScheduleUtilitiesReplaceSplitWorkspaceAndDetailSelection() {
        let navigation = SceneNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspace)

        navigation.openWorkspaceUtility(.agents)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitDetailColumn.root == .utility(.agents))
        #expect(navigation.splitColumnVisibility == .all)

        navigation.openWorkspaceUtility(.schedules)

        #expect(navigation.splitDetailColumn.root == .utility(.schedules))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func visibleUtilitiesStillRouteInSplitPresentation() {
        let navigation = SceneNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceUtility(.manageServers)
        #expect(navigation.splitDetailColumn.root == .utility(.manageServers))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func splitWorkspaceConfigurationPreservesWorkspaceBackLayerOnCompactRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceConfiguration(workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
    }

    @Test func stackWorkspaceConfigurationSurvivesRegularWidthRotation() {
        let navigation = SceneNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceConfiguration(workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
        #expect(navigation.splitDetailColumn.routes == [.workspace(workspaceTarget), .workspaceConfiguration(workspaceTarget)])
        #expect(navigation.splitColumnVisibility == .all)
    }

    /// The sidebar highlights the current place, which content opened on top keeps,
    /// and its All Sessions row makes All Sessions the detail column's root again.
    @Test func theCurrentPlaceFollowsTheSidebarAndOutlastsContentOnTop() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let session = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.currentPlace == .allSessions)

        navigation.openPlace(.utility(.agents))
        #expect(navigation.currentPlace == .utility(.agents))
        navigation.openWorkspaceSession(session)
        #expect(navigation.currentPlace == .utility(.agents), "A chat opened from Agents sits on top of it")

        navigation.openPlace(.allSessions)
        #expect(navigation.currentPlace == .allSessions)
        #expect(navigation.splitDetailColumn.root == .inbox)
        #expect(navigation.splitColumnVisibility == .all)

        let workspaceSession = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1", workspaceId: "workspace-1")
        navigation.openPlace(.sessions(workspace))
        navigation.openWorkspaceSession(workspaceSession, workspace: workspace)
        #expect(navigation.splitDetailColumn.routes == [.workspace(workspace), .session(workspaceSession)])
        #expect(navigation.currentPlace == .sessions(workspace), "The chat keeps its workspace's row selected")
        navigation.openPlace(.allSessions)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
        #expect(navigation.currentPlace == .allSessions)

        // The compact shell lists utilities over All Sessions and highlights none of them.
        navigation.setWorkspaceNavigationPresentation(.stack)
        navigation.openPlace(.utility(.agents))
        #expect(navigation.workspaceStackRouteElements == [.utility(.agents)])
        #expect(navigation.currentPlace == .allSessions)
        navigation.openPlace(.allSessions)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func utilitySelectionPreservesSplitColumnVisibility() {
        let navigation = readyNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspaceUtility(.appSettings)

        #expect(navigation.splitDetailColumn.root == .utility(.appSettings))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func sidebarPlacesHaveDistinctIdentifiers() {
        let items = WorkspaceSidebarPlaces.builtIn + [WorkspaceSidebarPlaces.appSettings]

        #expect(Set(items.map(\.accessibilityIdentifier)).count == items.count)
    }

    @Test func agentsAndExtensionsAreCompactUtilitiesWithDiagnostics() {
        let navigation = readyNavigation()

        navigation.openWorkspaceUtility(.agents)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_agents")

        navigation.openWorkspaceUtility(.extensions)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_extensions")
    }

    @Test func agentsAndExtensionsReplaceSplitSelectionAndKeepSidebarVisible() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspace)

        navigation.openWorkspaceUtility(.agents)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitDetailColumn.root == .utility(.agents))
        #expect(navigation.splitColumnVisibility == .all)

        navigation.openWorkspaceUtility(.extensions)
        #expect(navigation.splitDetailColumn.root == .utility(.extensions))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func extensionDetailPreservesUtilityRootAcrossWidthChanges() {
        let navigation = readyNavigation()
        let detail = ServerResourceDetailNavTarget(
            serverId: "server-b",
            kind: .extension,
            resourceId: "extension_opaque"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.extensions)

        navigation.openServerResourceDetail(detail)
        #expect(navigation.splitDetailColumn.root == .utility(.extensions))
        #expect(navigation.splitDetailColumn.pushed.count == 1)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_extension_detail")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailColumn.root == .utility(.extensions))
        #expect(navigation.splitDetailColumn.pushed.count == 1)
    }

    @Test func modelProvidersPushesServerScopedDestinationFromCompactInbox() {
        let navigation = readyNavigation()
        let target = ModelProvidersNavTarget(serverId: "server-a")

        navigation.openModelProviders(target)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "model_providers")
    }

    @Test func modelProvidersPreservesServerDetailsBackLayerAcrossWidthChanges() {
        let navigation = readyNavigation()
        let details = ServerDetailsNavTarget(serverId: "server-a")
        let providers = ModelProvidersNavTarget(serverId: "server-a")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.manageServers)
        navigation.openServerDetails(details)

        navigation.openModelProviders(providers)

        #expect(navigation.splitDetailColumn.root == .utility(.manageServers))
        #expect(navigation.splitDetailColumn.pushed.count == 2)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspaceStackRouteElements.count == 3)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "model_providers")

        navigation.popShownStack(toDepth: navigation.workspaceStackRouteElements.count - 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_details")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailColumn.root == .utility(.manageServers))
        #expect(navigation.splitDetailColumn.pushed.count == 1)
    }

    @Test func hostSwitcherOpensUsageThroughManageServersUtility() {
        let navigation = readyNavigation()

        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        #expect(navigation.visibleHostSwitcherDestination == .usage)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_manage_servers")
    }

    @Test func hostSwitcherSameDestinationDoesNotPushAgain() {
        let navigation = readyNavigation()
        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.visibleHostSwitcherDestination == .usage)
    }

    @Test func hostSwitcherReplacesSiblingJobsOnStack() {
        let navigation = readyNavigation()
        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-a")

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.visibleHostSwitcherDestination == .serverSettings)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_details")

        navigation.openHostSwitcherDestination(.modelProviders, serverId: "server-a")

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.visibleHostSwitcherDestination == .modelProviders)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "model_providers")
    }

    @Test func hostSwitcherServerMetricsReplacesUsageInBothShells() {
        let stack = readyNavigation()
        stack.openHostSwitcherDestination(.usage, serverId: "server-a")
        stack.openHostSwitcherDestination(.serverMetrics, serverId: "server-a")

        #expect(stack.workspaceStackRouteElements.count == 1)
        #expect(stack.visibleHostSwitcherDestination == .serverMetrics)
        #expect(stack.workspaceStackDiagnosticContext.screen == "utility_server_metrics")

        let split = readyNavigation()
        split.setWorkspaceNavigationPresentation(.split)
        split.openHostSwitcherDestination(.usage, serverId: "server-a")
        split.openHostSwitcherDestination(.serverMetrics, serverId: "server-a")

        #expect(split.visibleHostSwitcherDestination == .serverMetrics)
        #expect(split.splitDetailColumn.root == .utility(.serverMetrics))
        #expect(split.splitDetailColumn.pushed.isEmpty)
    }

    @Test func hostSwitcherUsageInSplitReplacesInboxWithoutPath() {
        let navigation = readyNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        #expect(navigation.visibleHostSwitcherDestination == .usage)
        #expect(navigation.splitDetailColumn.root == .utility(.manageServers))
        #expect(navigation.splitDetailColumn.pushed.isEmpty)
    }

    @Test func hostSwitcherSiblingsReplaceSplitPath() {
        let navigation = readyNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")

        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-a")

        #expect(navigation.visibleHostSwitcherDestination == .serverSettings)
        #expect(navigation.splitDetailColumn.rootIndex == nil)
        #expect(navigation.splitDetailColumn.pushed.count == 1)

        navigation.openHostSwitcherDestination(.modelProviders, serverId: "server-a")

        #expect(navigation.visibleHostSwitcherDestination == .modelProviders)
        #expect(navigation.splitDetailColumn.pushed.count == 1)
    }

    @Test func hostSwitcherDoesNotPopWhenOpeningTheVisibleJob() {
        let navigation = readyNavigation()
        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-a")
        let count = navigation.workspaceStackRouteElements.count

        navigation.openHostSwitcherDestination(.serverSettings, serverId: "server-b")

        #expect(navigation.workspaceStackRouteElements.count == count)
        #expect(navigation.visibleHostSwitcherDestination == .serverSettings)
    }

    private func readyNavigation() -> SceneNavigation {
        let navigation = SceneNavigation()
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        return navigation
    }
}

@Suite("Workspace stack/split presentation")
struct WorkspaceNavigationPresentationResolveTests {
    private func resolve(
        _ horizontal: UIUserInterfaceSizeClass,
        _ vertical: UIUserInterfaceSizeClass,
        _ width: CGFloat,
        _ height: CGFloat
    ) -> WorkspaceNavigationPresentation {
        WorkspaceNavigationPresentation.resolve(
            horizontalSizeClass: horizontal,
            verticalSizeClass: vertical,
            size: CGSize(width: width, height: height)
        )
    }

    /// iPhone Duo inner display (regular both ways): split in landscape,
    /// stack in portrait. A square regular window splits.
    @Test func regularBothWaysSplitsOnlyWhenAtLeastAsWideAsTall() {
        #expect(resolve(.regular, .regular, 951, 669) == .split)
        #expect(resolve(.regular, .regular, 669, 951) == .stack)
        #expect(resolve(.regular, .regular, 800, 800) == .split)
    }

    /// Duo outer display, iPad Slide Over, a large iPhone in landscape
    /// (regular width, compact height), or no trait yet.
    @Test func anyCompactOrMissingSizeClassKeepsTheStack() {
        #expect(resolve(.compact, .regular, 1366, 1024) == .stack)
        #expect(resolve(.regular, .compact, 956, 440) == .stack)
        #expect(resolve(.unspecified, .regular, 1366, 1024) == .stack)
        #expect(resolve(.regular, .unspecified, 1366, 1024) == .stack)
    }
}

@Suite("Workspace wiki-link file lookup policy")
struct WorkspaceWikiLinkFileLookupPolicyTests {
    @Test func deterministicAbsenceRecognizesOnlyMissingOrOutsideDirectoryListings() {
        #expect(WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.server(status: 404, message: "Directory not found")
        ))
        #expect(WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.server(status: 403, message: "Path is outside the workspace")
        ))
        #expect(WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.codedServer(status: 404, message: "Directory not found", code: "not_found")
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.server(status: 500, message: "boom")
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.codedServer(status: 500, message: "boom", code: "internal")
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.invalidResponse
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            URLError(.timedOut)
        ))
    }

    @Test func worktreeAbsenceFallsBackToMainCheckout() {
        #expect(WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "wt_feature",
            outcome: .absent
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "wt_feature",
            outcome: .present
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "wt_feature",
            outcome: .truncated
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "wt_feature",
            outcome: .unavailable
        ))
    }

    @Test func mainCheckoutAndMissingWorktreeNeverFallBack() {
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: nil,
            outcome: .absent
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "main",
            outcome: .absent
        ))
        #expect(!WorkspaceWikiLinkFileLookupPolicy.shouldFallBackToMainCheckout(
            worktreeID: "",
            outcome: .absent
        ))
    }

    @Test func missingOrForeignSourceSessionListsMainCheckout() {
        // The reported hole: a wiki-link tap whose source session is absent
        // from the in-memory store (or belongs to another workspace) must not
        // fail closed as "right now". It must list the main checkout (nil).
        #expect(WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: false,
            sourceSessionWorktreeID: nil
        ) == nil)
        #expect(WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: false,
            sourceSessionWorktreeID: "wt_feature"
        ) == nil)
    }

    @Test func resolvedSourceSessionKeepsItsCheckout() {
        #expect(WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: true,
            sourceSessionWorktreeID: "wt_feature"
        ) == "wt_feature")
        #expect(WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: true,
            sourceSessionWorktreeID: nil
        ) == nil)
    }

    @Test func missingSourceSessionStillListsExistingMainCheckoutSkillFile() {
        // The original toast: tap [[.pi/skills/...#L103-L123]] from a rendered
        // chat whose source session is not in memory. Lookup must still list
        // the main checkout instead of returning unavailable / "right now".
        let checkout = WorkspaceWikiLinkFileLookupPolicy.resolvedCheckout(
            sourceSessionResolved: false,
            sourceSessionWorktreeID: "wt_feature",
            firstOutcome: .unavailable
        )
        #expect(checkout == nil)
    }

    @Test func worktreeAbsenceResolvesToMainCheckoutForExistingSkillFile() {
        let checkout = WorkspaceWikiLinkFileLookupPolicy.resolvedCheckout(
            sourceSessionResolved: true,
            sourceSessionWorktreeID: "wt_feature",
            firstOutcome: .absent
        )
        #expect(checkout == nil)
    }
}
