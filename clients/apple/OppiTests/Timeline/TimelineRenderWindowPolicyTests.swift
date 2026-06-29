import Testing
@testable import Oppi

@Suite("Timeline render window policy")
struct TimelineRenderWindowPolicyTests {
    @Test func showEarlierControlRemainsVisibleWhenOnlyServerRowsRemain() {
        #expect(TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: true))
        #expect(!TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: false))
    }

    @Test func showEarlierRevealsLocalHiddenRowsBeforeFetchingOlderPage() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 200,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .revealLocal(newWindow: 140))
    }

    @Test func showEarlierFetchesOlderServerPageWhenLocalRowsAreExhausted() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .fetchOlderPage)
    }

    @Test func showEarlierDoesNothingWhenNoLocalOrServerRowsRemain() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: false
        )

        #expect(action == .none)
    }
}
