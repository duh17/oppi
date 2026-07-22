import SwiftUI
import Testing
@testable import Oppi

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
        let originalURL = try #require(WorkspaceWikiLinkURL.make(
            workspaceID: "workspace-1",
            filePath: "notes/sessions/oppi-jZhDRKeV.md"
        ))
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

    @Test func givenWorkspaceFileOutsideHostMountWhenResolvingThenItIsRejected() {
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

        #expect(resolved == nil)
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

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}
