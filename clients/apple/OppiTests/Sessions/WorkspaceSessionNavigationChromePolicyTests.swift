import Testing
@testable import Oppi

@Suite("Workspace session navigation chrome")
struct WorkspaceSessionNavigationChromePolicyTests {
    @Test func keepsSessionListBottomBarAutomatic() {
        #expect(!WorkspaceSessionNavigationChromePolicy.shouldHideBottomBar(on: .sessionList))
    }

    @Test func hidesBottomBarOnSessionTimeline() {
        #expect(WorkspaceSessionNavigationChromePolicy.shouldHideBottomBar(on: .sessionTimeline))
    }
}
