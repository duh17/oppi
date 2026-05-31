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

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}
