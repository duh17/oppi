import Testing
@testable import Oppi

@Suite("Workspace session navigation chrome")
struct WorkspaceSessionNavigationChromePolicyTests {
    @Test func hidesBottomBarWhileOpeningSession() {
        #expect(WorkspaceSessionNavigationChromePolicy.shouldHideBottomBar(isOpeningSession: true))
    }

    @Test func showsBottomBarWhenSessionListIsActive() {
        #expect(!WorkspaceSessionNavigationChromePolicy.shouldHideBottomBar(isOpeningSession: false))
    }
}
