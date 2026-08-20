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

@Suite("AppNavigation shell routing")
@MainActor
struct AppNavigationShellRoutingTests {
    @Test func workspacesSelectionLeavesPathUntouched() {
        let navigation = readyNavigation()
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)
        navigation.selectedTab = .workspaces

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == nil)
        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 1)
    }

    @Test func legacyServerSelectionRoutesToManageServersUtility() {
        let navigation = readyNavigation()
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)
        navigation.selectedTab = .server

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == .manageServers)
        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 1)
    }

    @Test func legacySettingsSelectionRoutesToSettingsUtility() {
        let navigation = readyNavigation()
        navigation.selectedTab = .settings

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == .appSettings)
        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 1)
    }

    @Test func legacySelectionDoesNotRouteDuringOnboarding() {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = true
        navigation.selectedTab = .server

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == nil)
        #expect(navigation.selectedTab == .server)
        #expect(navigation.workspacePath.count == 0)
    }

    @Test func legacySelectionDoesNotRouteBeforeLaunchIsReady() {
        let navigation = AppNavigation()
        navigation.launchPhase = .resolving
        navigation.showOnboarding = false
        navigation.selectedTab = .settings

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == nil)
        #expect(navigation.selectedTab == .settings)
        #expect(navigation.workspacePath.count == 0)
    }

    @Test func pairedLaunchRevealNeverShowsOnboarding() {
        let navigation = AppNavigation()
        navigation.showOnboarding = true

        navigation.revealPairedServerShell()

        #expect(navigation.launchPhase == .ready)
        #expect(!navigation.showOnboarding)
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

    @Test func failedInviteCannotShowOnboardingWhenAnyPairingExists() {
        #expect(!AppLaunchPairingPolicy.shouldShowOnboardingAfterInviteFailure(
            pairedServerCount: 1
        ))
        #expect(AppLaunchPairingPolicy.shouldShowOnboardingAfterInviteFailure(
            pairedServerCount: 0
        ))
    }

    @Test func inAppSessionLinkParserAcceptsOnlyCanonicalSessionRoute() throws {
        let canonical = try #require(URL(string: "oppi://session/child%2D1?workspaceId=ignored"))
        let extraPath = try #require(URL(string: "oppi://session/child/extra"))
        let workspace = try #require(URL(string: "oppi://workspace?path=/tmp/project"))
        let web = try #require(URL(string: "https://example.com/session/child-1"))

        #expect(InAppSessionLink.parse(canonical) == InAppSessionLink(sessionId: "child-1"))
        #expect(InAppSessionLink.parse(extraPath) == nil)
        #expect(InAppSessionLink.parse(workspace) == nil)
        #expect(InAppSessionLink.parse(web) == nil)
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

    @Test func workspaceSessionPathBuilderCreatesSingleDestination() {
        let path = AppNavigation.workspaceSessionPath(serverId: "server-1", sessionId: "session-1")

        #expect(path.count == 1)
    }

    @Test func setWorkspaceSessionPathReplacesExistingStackInOneAssignment() {
        let navigation = AppNavigation()
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.manageServers)

        navigation.setWorkspaceSessionPath(serverId: "server-1", sessionId: "session-1")

        #expect(navigation.workspacePath.count == 1)
    }

    @Test func externalSessionDeepLinkPolicyReplacesKnownAndRootsUnknownTargets() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "in-app-target")

        navigation.openSession(
            WorkspaceSessionNavTarget(
                serverId: "server-1",
                sessionId: "external-target",
                workspaceId: "workspace-1"
            ),
            source: .externalURL
        )

        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "external-target")

        for presentation in [
            WorkspaceNavigationPresentation.stack,
            WorkspaceNavigationPresentation.split,
        ] {
            let missingTargetNavigation = AppNavigation()
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

            MissingSessionDeepLinkNavigationPolicy.showWorkspaceRoot(in: missingTargetNavigation)

            #expect(missingTargetNavigation.selectedTab == .workspaces)
            #expect(missingTargetNavigation.workspacePath.count == 0)
            #expect(missingTargetNavigation.splitSelectedWorkspace == nil)
            #expect(missingTargetNavigation.splitDetailTarget == nil)
            #expect(missingTargetNavigation.splitDetailPath.count == 0)
            #expect(missingTargetNavigation.workspaceStackDiagnosticContext == .inboxAll)
            #expect(missingTargetNavigation.visibleSplitDiagnosticContext.screen == "workspace_split_inbox_all")
        }
    }

    @Test func referencedSessionAppendsToCompactChatHistoryAndSelfLinkIsNoOp() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "target")
        navigation.openReferencedSession(target)
        #expect(navigation.workspacePath.count == 2)
        navigation.workspacePath.removeLast()
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "source")
    }

    @Test func referencedSessionPushesFromSplitChatAndSelfLinkIsNoOp() {
        let navigation = AppNavigation()
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

        #expect(navigation.splitDetailTarget == .session(source))
        #expect(navigation.splitDetailPath.count == 1)
        #expect(navigation.visibleSplitDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "chat",
            sessionId: "target",
            workspaceId: "workspace-2"
        ))
        navigation.openReferencedSession(target)
        #expect(navigation.splitDetailPath.count == 1)
        navigation.splitDetailPath.removeLast()
        #expect(navigation.splitDetailTarget == .session(source))
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
            let navigation = AppNavigation()
            navigation.setWorkspaceNavigationPresentation(presentation)
            navigation.openWorkspaceSession(source)

            navigation.openReferencedWorkspaceLinkedFile(
                file,
                workspace: workspace,
                sourceSession: source
            )

            switch presentation {
            case .stack:
                #expect(navigation.workspacePath.count == 2)
                #expect(navigation.selectedWorkspaceFilter == nil)
                navigation.workspacePath.removeLast()
                #expect(navigation.workspacePath.count == 1)
                #expect(navigation.selectedWorkspaceFilter == nil)
            case .split:
                #expect(navigation.splitDetailTarget == .session(source))
                #expect(navigation.splitDetailPath.count == 1)
                navigation.splitDetailPath.removeLast()
                #expect(navigation.splitDetailTarget == .session(source))
            }
        }
    }

    @Test func referencedWorkspaceFileFallsBackToExplicitWorkspaceNavigationWhenSourceIsNotVisible() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.selectedWorkspaceFilter == workspace)
    }

    @Test func visibleSplitDiagnosticContextTracksNonSessionPathTop() {
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.skills)
        navigation.openServerResourceDetail(.init(
            serverId: "server-1",
            kind: .skill,
            resourceId: "skill-1"
        ))

        #expect(navigation.visibleSplitDiagnosticContext.screen == "server_skill_detail")
        #expect(navigation.visibleSplitDiagnosticContext.sessionId == nil)
        #expect(navigation.visibleSplitDiagnosticContext.workspaceId == nil)

        navigation.splitDetailPath.removeLast()
        #expect(navigation.visibleSplitDiagnosticContext.screen == "utility_skills")
    }

    @Test func referencedSessionChainSurvivesCompactToSplitToCompactTransition() {
        let navigation = AppNavigation()
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

        #expect(navigation.splitDetailTarget == .session(source))
        #expect(navigation.splitDetailPath.count == 1)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "target")
        navigation.workspacePath.removeLast()
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "source")
    }

    @Test func latestResourceReferenceRequestSuppressesSlowerEarlierCompletion() async {
        let coordinator = ResourceReferenceRequestCoordinator()
        let firstGate = ResourceReferenceAsyncGate()
        var committed: [String] = []

        coordinator.perform { token in
            await firstGate.wait()
            if coordinator.isCurrent(token) {
                committed.append("first")
            }
        }
        await Task.yield()
        coordinator.perform { token in
            if coordinator.isCurrent(token) {
                committed.append("second")
            }
        }
        for _ in 0..<10 { await Task.yield() }
        await firstGate.open()
        for _ in 0..<10 { await Task.yield() }

        #expect(committed == ["second"])
    }

    @Test func cancellingNewestResourceReferenceRequestSuppressesItsDialogAndOlderWork() async {
        let coordinator = ResourceReferenceRequestCoordinator()
        let firstGate = ResourceReferenceAsyncGate()
        let secondGate = ResourceReferenceAsyncGate()
        var committed: [String] = []

        coordinator.perform { token in
            await firstGate.wait()
            if coordinator.isCurrent(token) {
                committed.append("first")
            }
        }
        await Task.yield()
        coordinator.perform { token in
            await secondGate.wait()
            if coordinator.isCurrent(token) {
                committed.append("second dialog")
            }
        }
        coordinator.cancel()

        await firstGate.open()
        await secondGate.open()
        for _ in 0..<10 { await Task.yield() }

        #expect(committed.isEmpty)
    }

    @Test func supersededRequestDuringPreparationCannotActivateServerOrNavigate() async {
        let requestCoordinator = ResourceReferenceRequestCoordinator()
        let preparationGate = ResourceReferenceAsyncGate()
        let navigation = AppNavigation()
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

        requestCoordinator.perform { token in
            _ = await PreparedServerActivation.run(
                prepare: {
                    await preparationGate.wait()
                    return "server-stale"
                },
                shouldActivate: { requestCoordinator.isCurrent(token) },
                activate: { serverID in
                    activeServerID = serverID
                    navigation.openReferencedSession(staleSession)
                }
            )
        }
        await Task.yield()

        requestCoordinator.perform { token in
            #expect(requestCoordinator.isCurrent(token))
        }
        for _ in 0..<10 { await Task.yield() }
        await preparationGate.open()
        for _ in 0..<10 { await Task.yield() }

        #expect(activeServerID == "server-newer")
        #expect(navigation.workspacePath.count == 1)
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

    @Test func splitPresentationClearsStackPath() {
        let navigation = AppNavigation()
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .split)
        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func openWorkspacePushesInboxInStackPresentation() {
        let navigation = AppNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)

        navigation.openWorkspace(target)

        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.selectedWorkspaceFilter == target)
    }

    @Test func openWorkspaceUsesSplitSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspace(target)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.selectedWorkspaceFilter == target)
        #expect(navigation.splitSelectedWorkspace == target)
        #expect(navigation.splitSelectedSession == nil)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func showAllWorkspaceSessionsPopsWorkspaceInbox() {
        let navigation = AppNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.openWorkspace(target)

        navigation.showAllWorkspaceSessions()

        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspacePath.count == 0)
    }

    @Test func sessionOpenedFromWorkspaceBuildsAllWorkspaceChatHierarchy() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)

        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"),
            workspace: workspaceTarget
        )

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)

        navigation.workspacePath.removeLast()
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)

        navigation.workspacePath.removeLast()
        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.selectedWorkspaceFilter == nil)
    }

    @Test func sessionOpenedFromAllSessionsKeepsAllSessionsAsBackStop() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)

        navigation.workspacePath.removeLast()
        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.selectedWorkspaceFilter == nil)
    }

    @Test func stackDiagnosticContextTracksVisibleDestinationAcrossBackNavigation() {
        let navigation = AppNavigation()
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

        navigation.workspacePath.removeLast()
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

    @Test func externallyAppendedStackDestinationDoesNotReuseStaleWorkspaceOrSession() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)

        navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)

        #expect(navigation.workspaceStackDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "workspace_stack_unknown",
            sessionId: nil,
            workspaceId: nil
        ))
    }

    @Test func showSessionInboxInSplitClearsDetailTarget() {
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"))

        navigation.showSessionInboxInSplit()

        #expect(navigation.splitDetailTarget == nil)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func openSessionUsesSplitDetailSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        let target = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceSession(target)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedSession == target)
        #expect(navigation.splitColumnVisibility == .detailOnly)
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
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceUtility(.agents)

        navigation.openWorkspaceSession(.init(
            serverId: "server-1",
            sessionId: "control-1",
            routeScope: .control
        ))

        #expect(navigation.splitDetailTarget == .utility(.agents))
        #expect(navigation.splitDetailPath.count == 1)
        #expect(navigation.splitColumnVisibility == .detailOnly)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "control-1")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailTarget == .utility(.agents))
        #expect(navigation.splitDetailPath.count == 1)
    }

    @Test func openSessionPreservesWorkspaceHintFromWorkspaceTarget() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        #expect(navigation.splitSelectedSession?.workspaceId == "workspace-1")
    }

    @Test func workspaceSelectionRestoresSessionLayerVisibility() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspace(workspaceTarget)

        #expect(navigation.splitColumnVisibility == .all)
        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitSelectedSession == nil)
    }

    @Test func sessionSelectionPreservesSplitColumnVisibility() {
        let navigation = AppNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspaceSession(sessionTarget)

        #expect(navigation.splitColumnVisibility == .detailOnly)
        #expect(navigation.splitSelectedSession == sessionTarget)
    }

    @Test func fileBrowserUsesSplitDetailSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let fileTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "")
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceFileBrowser(fileTarget, workspace: workspaceTarget)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .fileBrowser(fileTarget))
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func linkedFileUsesDedicatedDestinationInSplitPresentation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let fileTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "server/src/server.ts", fileName: "server.ts")
        )
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceLinkedFile(fileTarget, workspace: workspaceTarget)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .linkedFile(fileTarget))
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func linkedFileTargetCarriesLineAnchorThroughNavigation() throws {
        let anchor = try #require(SourceLineAnchor.parse("#L12-L18"))
        let target = WorkspaceLinkedFileNavTarget.workspaceFile(
            serverId: "server-1",
            workspaceId: "workspace-1",
            path: "Sources/App.swift",
            lineAnchor: anchor
        )
        let navigation = AppNavigation()
        navigation.openWorkspaceLinkedFile(target)

        #expect(navigation.workspacePath.count == 1)
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
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceLinkedFile(target)

        #expect(navigation.splitDetailTarget == .linkedFile(target))

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 1)
    }

    @Test func linkedFileAppendsInStackPresentationToPreserveBackNavigation() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 2)
    }

    @Test func linkedFileOpenedFromSessionPreservesSessionBackNavigation() {
        let navigation = AppNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        let fileTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )

        navigation.openWorkspaceSession(sessionTarget)
        navigation.openWorkspaceLinkedFile(fileTarget)

        #expect(navigation.workspacePath.count == 2)
    }

    @Test func linkedFileOpenedFromSplitSessionPreservesSessionBackNavigation() {
        let navigation = AppNavigation()
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        let fileTarget = WorkspaceLinkedFileNavTarget(
            serverId: "server-1",
            workspaceId: "workspace-1",
            kind: .workspaceFile(path: "notes/second.md", fileName: "second.md")
        )
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceSession(sessionTarget)
        navigation.openWorkspaceLinkedFile(fileTarget)

        #expect(navigation.splitDetailTarget == .session(sessionTarget))
        #expect(navigation.splitDetailPath.count == 1)
    }

    @Test func linkedFileOpenedFromSplitSessionSurvivesCompactRotation() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 2)
    }

    @Test func linkedFileChainOpenedFromSplitFileSurvivesCompactRotation() {
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 2)
    }

    @Test func splitFileBrowserDirectoryDrillSurvivesCompactRotation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let rootTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "")
        let childTarget = FileBrowserNavTarget(serverId: "server-1", workspaceId: "workspace-1", path: "notes/")
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceFileBrowser(rootTarget, workspace: workspaceTarget)
        navigation.pushSplitDetailFileBrowser(childTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspacePath.count == 3)
    }

    @Test func splitWorkspaceSessionPreservesBothBackLayersOnCompactRotation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspacePath.count == 2)
    }

    @Test func stackWorkspaceSessionSurvivesRegularWidthRotation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(sessionTarget, workspace: workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .session(
            WorkspaceSessionNavTarget(
                serverId: "server-1",
                sessionId: "session-1",
                workspaceId: "workspace-1"
            )
        ))
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func stackFileBrowserDrillSurvivesRegularWidthRotation() {
        let navigation = AppNavigation()
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

        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .fileBrowser(rootTarget))
        #expect(navigation.splitDetailPath.count == 1)
        #expect(navigation.splitColumnVisibility == .detailOnly)
    }

    @Test func stackBackBeforeRegularWidthRotationKeepsWorkspaceDetail() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1"),
            workspace: workspaceTarget
        )
        navigation.workspacePath.removeLast()

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == nil)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func splitSystemBackBeforeCompactRotationDropsPoppedLinkedFile() {
        let navigation = AppNavigation()
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
        navigation.splitDetailPath.removeLast()
        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspacePath.count == 1)
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
        let navigation = AppNavigation()
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

        #expect(navigation.workspacePath.count == 3)
        #expect(navigation.selectedWorkspaceFilter == sourceWorkspace)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "linked_file")
        #expect(navigation.workspaceStackDiagnosticContext.workspaceId?.isEmpty != false)
    }

    @Test func utilityUsesSplitDetailSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceUtility(.appSettings)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitDetailTarget == .utility(.appSettings))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func agentAndScheduleUtilitiesAreReleaseEnabledAndAppendToStackPath() {
        let navigation = AppNavigation()

        #expect(WorkspaceUtilityNavTarget.agents.isReleaseEnabled)
        #expect(WorkspaceUtilityNavTarget.schedules.isReleaseEnabled)

        navigation.openWorkspaceUtility(.agents)

        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_agents")

        navigation.openWorkspaceUtility(.schedules)

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_schedules")
    }

    @Test func visibleUtilitiesStillAppendToStackPath() {
        let navigation = AppNavigation()

        navigation.openWorkspaceUtility(.manageServers)
        navigation.openWorkspaceUtility(.appSettings)

        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 2)
    }

    @Test func agentAndScheduleUtilitiesReplaceSplitWorkspaceAndDetailSelection() {
        let navigation = AppNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspace)

        navigation.openWorkspaceUtility(.agents)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitSelectedWorkspace == nil)
        #expect(navigation.splitDetailTarget == .utility(.agents))
        #expect(navigation.splitColumnVisibility == .all)

        navigation.openWorkspaceUtility(.schedules)

        #expect(navigation.splitDetailTarget == .utility(.schedules))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func visibleUtilitiesStillRouteInSplitPresentation() {
        let navigation = AppNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceUtility(.manageServers)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitDetailTarget == .utility(.manageServers))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func workspaceConfigurationUsesSplitDetailSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspaceConfiguration(workspaceTarget)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .workspaceConfiguration(workspaceTarget))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func splitWorkspaceConfigurationPreservesWorkspaceBackLayerOnCompactRotation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceConfiguration(workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.stack)

        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspaceTarget)
    }

    @Test func stackWorkspaceConfigurationSurvivesRegularWidthRotation() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceConfiguration(workspaceTarget)

        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == .workspaceConfiguration(workspaceTarget))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func showWorkspaceListKeepsCurrentSplitDetail() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        let sessionTarget = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspaceTarget)
        navigation.openWorkspaceSession(sessionTarget)
        navigation.splitColumnVisibility = .detailOnly

        navigation.showWorkspaceListInSplitSidebar()

        #expect(navigation.splitSelectedWorkspace == nil)
        #expect(navigation.splitSelectedSession == sessionTarget)
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func completingWorkspaceConfigurationClearsMatchingSplitDetail() {
        let navigation = AppNavigation()
        let workspaceTarget = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceConfiguration(workspaceTarget)

        navigation.completeWorkspaceConfiguration(workspaceTarget)

        #expect(navigation.splitSelectedWorkspace == workspaceTarget)
        #expect(navigation.splitDetailTarget == nil)
        #expect(navigation.splitDetailPath.count == 0)
    }

    @Test func legacySettingsSelectionRoutesToSplitDetailUtility() {
        let navigation = readyNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.selectedTab = .settings

        let routed = navigation.routeLegacySelectedTabIfNeeded()

        #expect(routed == .appSettings)
        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitDetailTarget == .utility(.appSettings))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func utilitySelectionPreservesSplitColumnVisibility() {
        let navigation = readyNavigation()
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.splitColumnVisibility = .detailOnly

        navigation.openWorkspaceUtility(.appSettings)

        #expect(navigation.splitDetailTarget == .utility(.appSettings))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func sidebarPrimaryUtilitiesHaveExactOrderSymbolsLabelsAndHitRegions() {
        let items = WorkspaceSidebarPrimaryUtilities.items

        #expect(items.map(\.target) == [.agents, .schedules, .skills, .extensions])
        #expect(items.map(\.systemImage) == [
            "person.crop.circle",
            "clock",
            "sparkles.rectangle.stack",
            "shippingbox",
        ])
        #expect(items.map(\.accessibilityLabel) == [
            "Agents",
            "Schedules",
            "Open Skills",
            "Open Extensions",
        ])
        #expect(items.map(\.accessibilityIdentifier) == [
            "workspace.agents.open",
            "workspace.schedules.open",
            "workspace.skills.open",
            "workspace.extensions.open",
        ])
        #expect(items.allSatisfy { $0.minimumHitHeight == 44 })
    }

    @Test func skillsAndExtensionsAreReleaseEnabledCompactUtilitiesWithDiagnostics() {
        let navigation = readyNavigation()

        #expect(WorkspaceUtilityNavTarget.skills.isReleaseEnabled)
        #expect(WorkspaceUtilityNavTarget.extensions.isReleaseEnabled)

        navigation.openWorkspaceUtility(.skills)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_skills")

        navigation.openWorkspaceUtility(.extensions)
        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_extensions")
    }

    @Test func skillsAndExtensionsReplaceSplitSelectionAndKeepSidebarVisible() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-1",
            workspace: makeTestWorkspace(id: "workspace-1")
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspace(workspace)

        navigation.openWorkspaceUtility(.skills)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitSelectedWorkspace == nil)
        #expect(navigation.splitDetailTarget == .utility(.skills))
        #expect(navigation.splitColumnVisibility == .all)

        navigation.openWorkspaceUtility(.extensions)
        #expect(navigation.splitDetailTarget == .utility(.extensions))
        #expect(navigation.splitColumnVisibility == .all)
    }

    @Test func skillDetailAndFilePreserveServerScopedRouteAcrossWidthChanges() {
        let navigation = readyNavigation()
        let detail = ServerResourceDetailNavTarget(
            serverId: "server-a",
            kind: .skill,
            resourceId: "skill_opaque"
        )
        let browser = ServerSkillBrowserNavTarget(
            serverId: "server-a",
            resourceId: "skill_opaque"
        )
        let file = ServerSkillFileNavTarget(
            serverId: "server-a",
            resourceId: "skill_opaque",
            path: "references/checklist.md"
        )

        navigation.openWorkspaceUtility(.skills)
        navigation.openServerResourceDetail(detail)
        navigation.openServerSkillBrowser(browser)
        navigation.openServerSkillFile(file)

        #expect(navigation.workspacePath.count == 4)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_file")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailTarget == .utility(.skills))
        #expect(navigation.splitDetailPath.count == 3)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 4)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_file")

        navigation.workspacePath.removeLast()
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_browser")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailTarget == .utility(.skills))
        #expect(navigation.splitDetailPath.count == 2)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 3)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_browser")
        #expect(browser.serverId == detail.serverId)
        #expect(file.resourceId == detail.resourceId)
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
        #expect(navigation.splitDetailTarget == .utility(.extensions))
        #expect(navigation.splitDetailPath.count == 1)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 2)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_extension_detail")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailTarget == .utility(.extensions))
        #expect(navigation.splitDetailPath.count == 1)
    }

    @Test func modelProvidersPushesServerScopedDestinationFromCompactInbox() {
        let navigation = readyNavigation()
        let target = ModelProvidersNavTarget(serverId: "server-a")

        navigation.openModelProviders(target)

        #expect(navigation.workspacePath.count == 1)
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

        #expect(navigation.splitDetailTarget == .utility(.manageServers))
        #expect(navigation.splitDetailPath.count == 2)

        navigation.setWorkspaceNavigationPresentation(.stack)
        #expect(navigation.workspacePath.count == 3)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "model_providers")

        navigation.workspacePath.removeLast()
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_details")

        navigation.setWorkspaceNavigationPresentation(.split)
        #expect(navigation.splitDetailTarget == .utility(.manageServers))
        #expect(navigation.splitDetailPath.count == 1)
    }

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}

@Suite("Workspace wiki-link file lookup policy")
struct WorkspaceWikiLinkFileLookupPolicyTests {
    @Test func deterministicAbsenceRecognizesOnly404DirectoryListings() {
        #expect(WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(
            APIError.server(status: 404, message: "Directory not found")
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
