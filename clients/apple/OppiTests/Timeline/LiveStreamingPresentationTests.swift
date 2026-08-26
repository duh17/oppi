import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Live streaming presentation owner")
@MainActor
struct LiveStreamingPresentationTests {
    @Test("shared cadence is the 50ms coalescer clock")
    func sharedCadenceMatchesCoalescer() {
        #expect(LiveStreamingPresentation.flushInterval == .milliseconds(50))
        #expect(DeltaCoalescer.flushInterval == LiveStreamingPresentation.flushInterval)
    }

    @Test("inner viewports share one attached detached settle policy")
    func sharedFollowPolicyAttachedDetachedSettle() {
        var policy = LiveStreamingPresentation.ViewportPolicy(followsTail: true)
        #expect(policy.handle(.requestFollowTail) == .followTail)

        #expect(policy.handle(.interactionBegan) == .none)
        #expect(policy.followsTail == false)
        #expect(policy.handle(.requestFollowTail) == .none)

        #expect(policy.handle(.interactionEnded(isNearBottom: false, isStreaming: true)) == .none)
        #expect(policy.followsTail == false)

        #expect(policy.handle(.interactionEnded(isNearBottom: true, isStreaming: true)) == .followTail)
        #expect(policy.followsTail == true)
        #expect(policy.handle(.requestFollowTail) == .followTail)

        #expect(policy.handle(.streamCompleted) == .none)
        #expect(policy.followsTail == false)
        #expect(policy.handle(.requestFollowTail) == .none)
    }

    @Test("stream ticks attach on first live update and preserve detached appends")
    func streamTicksMatchAttachCompleteRules() {
        var policy = LiveStreamingPresentation.ViewportPolicy(followsTail: false)
        #expect(policy.applyStreamTick(
            isStreaming: true,
            shouldRerender: true,
            wasVisible: false,
            previousText: nil,
            currentText: "line 1\n"
        ) == .none)
        #expect(policy.followsTail)

        #expect(policy.handle(.interactionBegan) == .none)
        #expect(policy.handle(.interactionEnded(isNearBottom: false, isStreaming: true)) == .none)
        #expect(!policy.followsTail)

        #expect(policy.applyStreamTick(
            isStreaming: true,
            shouldRerender: true,
            wasVisible: true,
            previousText: "line 1\n",
            currentText: "line 1\nline 2\n"
        ) == .none)
        #expect(!policy.followsTail)

        #expect(policy.applyStreamTick(
            isStreaming: false,
            shouldRerender: true,
            wasVisible: true,
            previousText: "line 1\nline 2\n",
            currentText: "line 1\nline 2\nfinal\n"
        ) == .none)
        #expect(!policy.followsTail)
    }

    @Test("thinking stream delivers every coalesced snapshot without a second clock")
    func thinkingStreamHasNoSecondClock() {
        let stream = ThinkingTraceStream(text: "Considering", isDone: false)
        var deliveries = 0
        _ = stream.addObserver(deliverImmediately: false) { _ in
            deliveries += 1
        }

        for index in 0..<8 {
            stream.update(text: "Considering \(index)", isDone: false)
        }

        #expect(deliveries == 8)
        #expect(stream.snapshot.text == "Considering 7")
    }

    @Test("mutable fullscreen applies every coalesced snapshot without a second clock")
    func mutableFullscreenHasNoSecondClock() {
        let body = NativeMutableFullScreenMarkdownBody(
            content: "Initial",
            isStreaming: true,
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let initialApplyCount = body.debugMutableApplyCountForTesting

        for index in 0..<8 {
            body.update(content: "Initial \(index)", isStreaming: true)
        }

        #expect(body.debugMutableApplyCountForTesting == initialApplyCount + 8)
    }

    @Test("append-only chunk fades and correction cancels then snaps")
    func appendFadeCancelsOnCorrection() throws {
        let animationDriver = MarkdownChunkSettleAnimationDriverSpy()
        let applier = makeMarkdownApplier(
            motionAllowed: { true },
            animationDriver: animationDriver
        )

        apply("Hello", isStreaming: true, to: applier)
        apply("Hello world", isStreaming: true, to: applier)

        #expect(applier.debugActiveChunkRangeForTesting == NSRange(location: 5, length: 6))
        #expect(applier.debugRenderingAlphaForTesting(at: 5) == 0)
        #expect(animationDriver.startCount == 1)

        animationDriver.advance(to: 0.5)
        let intermediateAlpha = try #require(applier.debugRenderingAlphaForTesting(at: 5))
        #expect(intermediateAlpha > 0)
        #expect(intermediateAlpha < 1)

        animationDriver.finish()
        #expect(applier.debugActiveChunkRangeForTesting == nil)
        #expect(applier.debugRenderingAlphaForTesting(at: 5) == nil)

        apply("Hello world!", isStreaming: true, to: applier)
        #expect(applier.debugActiveChunkRangeForTesting == NSRange(location: 11, length: 1))
        apply("Hello earth!", isStreaming: true, to: applier)
        #expect(animationDriver.cancelCount == 1)
        #expect(applier.debugActiveChunkRangeForTesting == nil)
        #expect(applier.debugRenderingAlphaForTesting(at: 11) == nil)
    }

    @Test("Reduce Motion gate snaps append and stream end cancels an active fade")
    func reducedMotionSnapsAndStreamEndCancels() {
        #expect(!MarkdownChunkSettleMotionGate.allows(
            reduceMotion: true,
            lowPower: false,
            thermalState: .nominal
        ))
        #expect(!MarkdownChunkSettleMotionGate.allows(
            reduceMotion: false,
            lowPower: true,
            thermalState: .nominal
        ))
        #expect(!MarkdownChunkSettleMotionGate.allows(
            reduceMotion: false,
            lowPower: false,
            thermalState: .serious
        ))

        let snappedDriver = MarkdownChunkSettleAnimationDriverSpy()
        let snappedApplier = makeMarkdownApplier(
            motionAllowed: { false },
            animationDriver: snappedDriver
        )
        apply("Hello", isStreaming: true, to: snappedApplier)
        apply("Hello world", isStreaming: true, to: snappedApplier)
        #expect(snappedDriver.startCount == 0)
        #expect(snappedApplier.debugActiveChunkRangeForTesting == nil)

        let activeDriver = MarkdownChunkSettleAnimationDriverSpy()
        let activeApplier = makeMarkdownApplier(
            motionAllowed: { true },
            animationDriver: activeDriver
        )
        apply("Hello", isStreaming: true, to: activeApplier)
        apply("Hello world", isStreaming: true, to: activeApplier)
        apply("Hello world", isStreaming: false, to: activeApplier)
        #expect(activeDriver.cancelCount == 1)
        #expect(activeApplier.debugActiveChunkRangeForTesting == nil)
        #expect(activeApplier.debugRenderingAlphaForTesting(at: 5) == nil)
    }

    @Test("cancelled fade paints full color before dropping the overlay")
    func cancelledFadePaintsFullColorBeforeDroppingOverlay() throws {
        let animationDriver = MarkdownChunkSettleAnimationDriverSpy()
        let applier = makeMarkdownApplier(
            motionAllowed: { true },
            animationDriver: animationDriver
        )

        apply("Hello", isStreaming: true, to: applier)
        apply("Hello world", isStreaming: true, to: applier)
        animationDriver.advance(to: 0.35)
        let fadedAlpha = try #require(applier.debugRenderingAlphaForTesting(at: 5))
        #expect(fadedAlpha > 0 && fadedAlpha < 1)

        apply("Hello worlds", isStreaming: true, to: applier)
        let snapAlpha = try #require(applier.debugCancelSnapAlphaForTesting)
        #expect(snapAlpha > 0.99, "cancel must paint the previous chunk at full color before removing the overlay")
        #expect(applier.debugRenderingAlphaForTesting(at: 5) == nil)
    }

    private func makeMarkdownApplier(
        motionAllowed: @escaping @MainActor @Sendable () -> Bool,
        animationDriver: MarkdownChunkSettleAnimationDriver
    ) -> AssistantMarkdownSegmentApplier {
        AssistantMarkdownSegmentApplier(
            stackView: UIStackView(),
            textViewDelegate: LiveStreamingTextViewDelegate(),
            chunkSettleMotionAllowed: motionAllowed,
            chunkSettleAnimationDriver: animationDriver
        )
    }

    private func apply(
        _ content: String,
        isStreaming: Bool,
        to applier: AssistantMarkdownSegmentApplier
    ) {
        applier.apply(
            segments: FlatSegment.build(from: parseCommonMark(content), themeID: .dark),
            config: .make(content: content, isStreaming: isStreaming, themeID: .dark)
        )
    }

    @Test("thinking overflow follow uses the shared policy")
    func thinkingOverflowFollowUsesSharedPolicy() {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "seed",
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: Array(repeating: "streaming thought line", count: 300).joined(separator: "\n"),
            fullText: nil
        )

        #expect(view.liveStreamingFollowsTailForTesting)
        #expect(view.contentIsTruncated)
        #expect(view.isShowingTailForTesting)

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "streaming thought line", count: 300).joined(separator: "\n")
        )
        #expect(!view.liveStreamingFollowsTailForTesting)
    }

    @Test("write-tool markdown follow uses the shared attach complete rules")
    func writeToolMarkdownFollowUsesSharedPolicy() {
        var state = LiveStreamingPresentation.ViewportPolicy(followsTail: false)
        let first = ToolRowMarkdownRenderStrategy.render(
            text: "# Title\n\nBody\n",
            isStreaming: true,
            expandedScrollView: UIScrollView(),
            previousSignature: nil,
            previousRenderedText: nil,
            previousAutoFollow: state.followsTail,
            wasExpandedVisible: false,
            isUsingMarkdownViewportLayout: false,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            textSelectionEnabled: false,
            viewportPolicy: .markdown(isCustomTool: false)
        )
        _ = state.applyStreamTick(
            isStreaming: true,
            shouldRerender: true,
            wasVisible: false,
            previousText: nil,
            currentText: "# Title\n\nBody\n"
        )
        #expect(first.shouldAutoFollow == state.followsTail)
        #expect(first.scrollBehavior == .followTail)

        let grown = "# Title\n\nBody\n\nMore tail\n"
        let second = ToolRowMarkdownRenderStrategy.render(
            text: grown,
            isStreaming: true,
            expandedScrollView: UIScrollView(),
            previousSignature: first.renderSignature,
            previousRenderedText: first.renderedText,
            previousAutoFollow: false,
            wasExpandedVisible: true,
            isUsingMarkdownViewportLayout: true,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            textSelectionEnabled: false,
            viewportPolicy: .markdown(isCustomTool: false)
        )
        var detached = LiveStreamingPresentation.ViewportPolicy(followsTail: false)
        _ = detached.applyStreamTick(
            isStreaming: true,
            shouldRerender: true,
            wasVisible: true,
            previousText: first.renderedText,
            currentText: grown
        )
        #expect(second.shouldAutoFollow == detached.followsTail)
        #expect(second.scrollBehavior == .preserve)
    }
}

@MainActor
private final class MarkdownChunkSettleAnimationDriverSpy: MarkdownChunkSettleAnimationDriver {
    private var update: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(
        duration: TimeInterval,
        update: @escaping (CGFloat) -> Void,
        completion: @escaping () -> Void
    ) {
        _ = duration
        startCount += 1
        self.update = update
        self.completion = completion
    }

    func cancel() {
        cancelCount += 1
        update = nil
        completion = nil
    }

    func advance(to progress: CGFloat) {
        update?(progress)
    }

    func finish() {
        update?(1)
        completion?()
        update = nil
        completion = nil
    }
}

@MainActor
private final class LiveStreamingTextViewDelegate: NSObject, UITextViewDelegate {}
