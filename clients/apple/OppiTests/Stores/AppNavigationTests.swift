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

    @Test func openWorkspaceUsesSplitSelectionInSplitPresentation() {
        let navigation = AppNavigation()
        let target = WorkspaceNavTarget(serverId: "server-1", workspace: makeTestWorkspace(id: "workspace-1"))
        navigation.setWorkspaceNavigationPresentation(.split)

        navigation.openWorkspace(target)

        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.splitSelectedWorkspace == target)
        #expect(navigation.splitSelectedSession == nil)
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
        let fileTarget = FileBrowserNavTarget(workspaceId: "workspace-1", path: "")
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

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}
