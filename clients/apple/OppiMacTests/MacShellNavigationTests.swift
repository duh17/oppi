import Testing
@testable import Oppi

@Suite("Mac shell navigation")
struct MacShellNavigationTests {

    @Test func pairingIsCompanionToolNotClientPrerequisite() {
        #expect(MacSidebarSection.pairDevices.title == "Pair Devices")
        #expect(MacSidebarSection.pairDevices.group == .tools)
        #expect(MacSidebarSection.workspaces.group == .client)
        #expect(MacSidebarSection.localServer.group == .servers)
    }

    @Test func shellIncludesLocalAndRemoteServerEntries() {
        #expect(MacSidebarSection.allCases.contains(.localServer))
        #expect(MacSidebarSection.allCases.contains(.remoteServers))
    }

    @Test func sidebarGroupsHaveUserVisibleTitles() {
        for group in MacSidebarGroup.allCases {
            #expect(!group.title.isEmpty)
        }
    }
}
