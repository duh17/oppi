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

    @Test("neutral streaming append converts only the attributed suffix")
    func streamingNeutralAppendConvertsDeltaNotWholeTail() throws {
        let stack = UIStackView()
        let applier = makeMarkdownApplier(stackView: stack, motionAllowed: { false })

        apply("Hello", isStreaming: true, to: applier)
        #expect(applier.debugStreamingFullNSConversionCountForTesting == 0)
        #expect(applier.debugStreamingDeltaNSConversionCountForTesting == 0)

        apply("Hello world", isStreaming: true, to: applier)
        #expect(
            applier.debugStreamingDeltaNSConversionCountForTesting == 1,
            "Append-only ticks must convert the new suffix, not the whole tail"
        )
        #expect(
            applier.debugStreamingFullNSConversionCountForTesting == 0,
            "Markdown-neutral append must not rebuild NSAttributedString for the prefix"
        )

        let textView = try #require(firstTextView(in: stack))
        #expect(timelineRenderedText(of: textView) == "Hello world")
    }

    @Test("streaming append keeps the TextKit 2 document and layouts only a partial range")
    func streamingAppendKeepsLongLivedStorageAndPartialLayout() throws {
        let stack = UIStackView()
        let applier = makeMarkdownApplier(stackView: stack, motionAllowed: { false })

        apply("Hello", isStreaming: true, to: applier)
        let storageID = try #require(applier.debugTextContentStorageIdentifierForTesting())
        let documentLayoutsAfterSeed = applier.debugStreamingDocumentLayoutCountForTesting
        let partialLayoutsAfterSeed = applier.debugStreamingPartialLayoutCountForTesting
        #expect(documentLayoutsAfterSeed == 0)
        #expect(partialLayoutsAfterSeed == 0)

        apply("Hello world", isStreaming: true, to: applier)
        #expect(applier.debugTextContentStorageIdentifierForTesting() == storageID)
        #expect(
            applier.debugStreamingDocumentLayoutCountForTesting == documentLayoutsAfterSeed,
            "Streaming append must not force TextKit layout of the whole document"
        )
        #expect(applier.debugStreamingPartialLayoutCountForTesting > partialLayoutsAfterSeed)

        let partialLayoutsAfterFirstAppend = applier.debugStreamingPartialLayoutCountForTesting
        apply("Hello world!", isStreaming: true, to: applier)
        #expect(applier.debugTextContentStorageIdentifierForTesting() == storageID)
        #expect(applier.debugStreamingDocumentLayoutCountForTesting == documentLayoutsAfterSeed)
        #expect(applier.debugStreamingPartialLayoutCountForTesting > partialLayoutsAfterFirstAppend)
    }

    @Test("CommonMark inline rewrites replace the tail instead of appending over stale glyphs")
    func streamingInlineMarkdownRewriteDoesNotGarblePrefix() throws {
        try expectStreamingRewrite(
            open: "This is **bol",
            closed: "This is **bold** text",
            expected: "This is bold text",
            forbidden: "**"
        )
        try expectStreamingRewrite(
            open: "Use `fo",
            closed: "Use `foo()` here",
            expected: "Use foo() here",
            forbidden: "`"
        )
        try expectStreamingRewrite(
            open: "See [lin",
            closed: "See [link](https://example.com) now",
            expected: "See link now",
            forbidden: "["
        )
    }

    @Test("links, code spans, and tables stay put while later prose streams")
    func streamingPrefixMarksAndTablesDoNotFlicker() throws {
        let stack = UIStackView()
        let applier = makeMarkdownApplier(stackView: stack, motionAllowed: { false })
        let prefix = """
        Use `foo()` and [docs](https://example.com) first.

        | A | B |
        | --- | --- |
        | 1 | 2 |

        Tail
        """

        apply(prefix, isStreaming: true, to: applier)
        let textView = try #require(firstTextView(in: stack))
        let table = try #require(stack.arrangedSubviews.compactMap { $0 as? NativeTableBlockView }.first)
        let tableID = ObjectIdentifier(table)
        let ns = try #require(textView.attributedText)
        let codeRange = (ns.string as NSString).range(of: "foo()")
        let linkRange = (ns.string as NSString).range(of: "docs")
        #expect(codeRange.location != NSNotFound)
        #expect(linkRange.location != NSNotFound)
        #expect(ns.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)
        let tableAppliesAfterMount = applier.debugInPlaceTableApplyCountForTesting

        apply(prefix + " continues", isStreaming: true, to: applier)
        let updated = try #require(firstTextView(in: stack))
        let updatedNS = try #require(updated.attributedText)
        #expect((updatedNS.string as NSString).range(of: "foo()") == codeRange)
        #expect((updatedNS.string as NSString).range(of: "docs") == linkRange)
        #expect(updatedNS.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)
        #expect(ObjectIdentifier(try #require(stack.arrangedSubviews.compactMap { $0 as? NativeTableBlockView }.first)) == tableID)
        #expect(applier.debugInPlaceTableApplyCountForTesting == tableAppliesAfterMount)
        #expect(applier.debugStreamingDeltaNSConversionCountForTesting >= 1)
    }

    @Test("content view streaming rewrite and append keep glyphs and use a suffix delta")
    func streamingContentViewKeepsGlyphsOnRewriteAndDeltaOnAppend() throws {
        let view = AssistantMarkdownContentView()
        view.apply(configuration: .make(content: "This is **bol", isStreaming: true, themeID: .dark))
        view.apply(configuration: .make(content: "This is **bold** text", isStreaming: true, themeID: .dark))

        let rewritten = try #require(timelineAllTextViews(in: view).first)
        #expect(timelineRenderedText(of: rewritten) == "This is bold text")
        #expect(applierStorageID(of: view) != nil)

        let storageID = try #require(view.debugTextContentStorageIdentifierForTesting)
        let fullBeforeAppend = view.debugStreamingFullNSConversionCountForTesting
        let documentLayoutsAfterRewrite = view.debugStreamingDocumentLayoutCountForTesting
        let partialLayoutsAfterRewrite = view.debugStreamingPartialLayoutCountForTesting
        #expect(documentLayoutsAfterRewrite == 0)
        view.apply(configuration: .make(content: "This is **bold** text now", isStreaming: true, themeID: .dark))

        let appended = try #require(timelineAllTextViews(in: view).first)
        #expect(timelineRenderedText(of: appended) == "This is bold text now")
        #expect(view.debugTextContentStorageIdentifierForTesting == storageID)
        #expect(view.debugStreamingDeltaNSConversionCountForTesting >= 1)
        #expect(view.debugStreamingFullNSConversionCountForTesting == fullBeforeAppend)
        #expect(view.debugStreamingDocumentLayoutCountForTesting == 0)
        #expect(view.debugStreamingDocumentLayoutCountForTesting == documentLayoutsAfterRewrite)
        #expect(view.debugStreamingPartialLayoutCountForTesting > partialLayoutsAfterRewrite)
    }

    private func makeMarkdownApplier(
        stackView: UIStackView = UIStackView(),
        motionAllowed: @escaping @MainActor @Sendable () -> Bool,
        animationDriver: MarkdownChunkSettleAnimationDriver = MarkdownChunkSettleAnimationDriverSpy()
    ) -> AssistantMarkdownSegmentApplier {
        AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: LiveStreamingTextViewDelegate(),
            chunkSettleMotionAllowed: motionAllowed,
            chunkSettleAnimationDriver: animationDriver
        )
    }

    private func firstTextView(in stack: UIStackView) -> UITextView? {
        stack.arrangedSubviews.compactMap { $0 as? UITextView }.first
    }

    private func applierStorageID(of view: AssistantMarkdownContentView) -> ObjectIdentifier? {
        view.debugTextContentStorageIdentifierForTesting
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

    private func expectStreamingRewrite(
        open: String,
        closed: String,
        expected: String,
        forbidden: String
    ) throws {
        let stack = UIStackView()
        let applier = makeMarkdownApplier(stackView: stack, motionAllowed: { false })
        apply(open, isStreaming: true, to: applier)
        apply(closed, isStreaming: true, to: applier)

        let textView = try #require(firstTextView(in: stack))
        let rendered = timelineRenderedText(of: textView)
        #expect(rendered == expected, "Expected \(expected), got \(rendered)")
        #expect(!rendered.contains(forbidden), "Rewrite left markup glyphs in \(rendered)")
        #expect(applier.debugStreamingFullNSConversionCountForTesting >= 1)
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
