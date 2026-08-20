import Testing
@testable import Oppi

@Suite("Workspace inbox sidebar scroll policy")
struct WorkspaceInboxSidebarScrollPolicyTests {
    @Test func closedInboxKeepsScrollingAndIndicators() {
        #expect(
            !WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: false,
                sidebarProgress: 0
            )
        )
        #expect(
            !WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 0
            )
        )
    }

    @Test func verticalEdgeDragLeavesInboxScrolling() {
        #expect(
            !WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: false,
                sidebarProgress: 0
            )
        )
        #expect(
            !WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 0
            )
        )
    }

    @Test func horizontalRevealStopsInboxScrollingBeforeProgressMoves() {
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: true,
                sidebarProgress: 0
            )
        )
        #expect(
            !WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 0
            )
        )
    }

    @Test func peekingInboxHidesIndicatorsAndStopsScrolling() {
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: true,
                sidebarProgress: 0.3
            )
        )
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 0.3
            )
        )
    }

    @Test func settledOpenPeekHidesIndicatorsWithoutADrag() {
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: false,
                sidebarProgress: 1
            )
        )
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 1
            )
        )
    }

    @Test func settlingClosedKeepsIndicatorsHiddenUntilRest() {
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: false,
                sidebarProgress: 0.2
            )
        )
        #expect(
            WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: 0.2
            )
        )
    }
}
