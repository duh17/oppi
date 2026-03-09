import Testing
@testable import Oppi

@Suite("Zen timeline render window policy")
struct ZenTimelineRenderWindowPolicyTests {
    @Test("attached zen shrinks to monitor window")
    func attachedZenShrinksToMonitorWindow() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: 120,
            totalItems: 200,
            isZenMode: true,
            isNearBottom: true
        )

        #expect(synced == ZenTimelineRenderWindowPolicy.zenAttachedWindow)
    }

    @Test("detached zen restores at least the standard floor")
    func detachedZenRestoresStandardFloor() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: 40,
            totalItems: 200,
            isZenMode: true,
            isNearBottom: false
        )

        #expect(synced == ZenTimelineRenderWindowPolicy.standardWindow)
    }

    @Test("normal mode preserves larger manual history window")
    func normalModePreservesLargerManualHistoryWindow() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: 220,
            totalItems: 500,
            isZenMode: false,
            isNearBottom: false
        )

        #expect(synced == 220)
    }

    @Test("small timelines clamp to available item count")
    func smallTimelinesClampToAvailableItemCount() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: 80,
            totalItems: 12,
            isZenMode: false,
            isNearBottom: true
        )

        #expect(synced == 12)
    }

    @Test("attached zen on small timelines still clamps to available item count")
    func attachedZenOnSmallTimelinesClampsToAvailableItemCount() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: 80,
            totalItems: 12,
            isZenMode: true,
            isNearBottom: true
        )

        #expect(synced == 12)
    }

    @Test("negative current window clamps before applying policy")
    func negativeCurrentWindowClampsBeforeApplyingPolicy() {
        let synced = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: -10,
            totalItems: 200,
            isZenMode: false,
            isNearBottom: false
        )

        #expect(synced == ZenTimelineRenderWindowPolicy.standardWindow)
    }
}
