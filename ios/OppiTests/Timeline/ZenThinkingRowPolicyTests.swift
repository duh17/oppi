import Testing
@testable import Oppi

@Suite("Zen thinking row policy")
@MainActor
struct ZenThinkingRowPolicyTests {
    @Test("attached zen uses taller cap only while streaming")
    func attachedZenUsesTallerCapOnlyWhileStreaming() {
        #expect(
            ZenThinkingRowPolicy.maxBubbleHeight(
                isDone: false,
                isZenMode: true,
                isNearBottom: true
            ) == ZenThinkingRowPolicy.zenAttachedStreamingMaxBubbleHeight
        )

        #expect(
            ZenThinkingRowPolicy.maxBubbleHeight(
                isDone: true,
                isZenMode: true,
                isNearBottom: true
            ) == ZenThinkingRowPolicy.defaultMaxBubbleHeight
        )
    }

    @Test("detached or non-zen uses default cap")
    func detachedOrNonZenUsesDefaultCap() {
        #expect(
            ZenThinkingRowPolicy.maxBubbleHeight(
                isDone: false,
                isZenMode: true,
                isNearBottom: false
            ) == ZenThinkingRowPolicy.defaultMaxBubbleHeight
        )

        #expect(
            ZenThinkingRowPolicy.maxBubbleHeight(
                isDone: false,
                isZenMode: false,
                isNearBottom: true
            ) == ZenThinkingRowPolicy.defaultMaxBubbleHeight
        )
    }

    @Test("row builder applies taller cap only for attached zen streaming thinking")
    func rowBuilderAppliesTallerCapOnlyForAttachedZenStreamingThinking() throws {
        let harness = makeTimelineHarness(sessionId: "session-thinking-zen")
        let item = ChatItem.thinking(
            id: "thinking-1",
            preview: Array(repeating: "thinking", count: 120).joined(separator: "\n"),
            hasMore: true,
            isDone: false
        )

        harness.scrollController.updateNearBottom(true)
        let attachedConfig = makeTimelineConfiguration(
            items: [item],
            isBusy: true,
            isZenMode: true,
            sessionId: harness.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            toolSegmentStore: harness.toolSegmentStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: attachedConfig, to: harness.collectionView)
        let attached = try #require(harness.coordinator.thinkingRowConfiguration(itemID: item.id, item: item))
        #expect(attached.maxBubbleHeight == ZenThinkingRowPolicy.zenAttachedStreamingMaxBubbleHeight)

        harness.scrollController.updateNearBottom(false)
        let detachedConfig = makeTimelineConfiguration(
            items: [item],
            isBusy: true,
            isZenMode: true,
            sessionId: harness.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            toolSegmentStore: harness.toolSegmentStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: detachedConfig, to: harness.collectionView)
        let detached = try #require(harness.coordinator.thinkingRowConfiguration(itemID: item.id, item: item))
        #expect(detached.maxBubbleHeight == ZenThinkingRowPolicy.defaultMaxBubbleHeight)
    }
}
