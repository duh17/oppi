import Testing
import UIKit
@testable import Oppi

@Suite("Tool timeline row viewport policy")
@MainActor
struct ToolTimelineRowViewportPolicyTests {
    @Test func bucketedCodeViewportSkipsMeasurementClosure() {
        var cache = ToolTimelineRowViewportHeightCache()
        var measured = false

        let height = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &cache,
            signature: 1,
            widthBucket: 360,
            mode: .expandedCode,
            inputBytes: 9_000,
            profile: ToolTimelineRowViewportProfile(kind: .code, inputBytes: 9_000, lineCount: 140),
            availableHeight: 700
        ) {
            measured = true
            return 999
        }

        #expect(!measured, "Bucketed expanded code should not synchronously measure on first reveal")
        #expect(height == 420)
    }

    @Test func shortTextViewportStaysCompact() {
        var cache = ToolTimelineRowViewportHeightCache()

        let height = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &cache,
            signature: 1,
            widthBucket: 360,
            mode: .expandedText,
            inputBytes: 28,
            profile: ToolTimelineRowViewportProfile(kind: .text, inputBytes: 28, lineCount: 1),
            availableHeight: 700
        ) {
            999
        }

        #expect(height < 120, "Short expanded text should stay compact; got \(height)")
    }

    @Test func codeAndDiffUseSameLargeViewportBuckets() {
        var codeCache = ToolTimelineRowViewportHeightCache()
        var diffCache = ToolTimelineRowViewportHeightCache()

        let codeHeight = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &codeCache,
            signature: 1,
            widthBucket: 360,
            mode: .expandedCode,
            inputBytes: 12_000,
            profile: ToolTimelineRowViewportProfile(kind: .code, inputBytes: 12_000, lineCount: 160),
            availableHeight: 700
        ) { 999 }

        let diffHeight = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &diffCache,
            signature: 1,
            widthBucket: 360,
            mode: .expandedDiff,
            inputBytes: 12_000,
            profile: ToolTimelineRowViewportProfile(kind: .diff, inputBytes: 12_000, lineCount: 160),
            availableHeight: 700
        ) { 999 }

        #expect(codeHeight == diffHeight)
        #expect(codeHeight == 420)
    }

    @Test func largeMarkdownViewportIsBounded() {
        var cache = ToolTimelineRowViewportHeightCache()

        let height = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &cache,
            signature: 1,
            widthBucket: 360,
            mode: .expandedText,
            inputBytes: 18_000,
            profile: ToolTimelineRowViewportProfile(kind: .markdown, inputBytes: 18_000, lineCount: 40),
            availableHeight: 700
        ) { 999 }

        #expect(height == 480)
    }

    @Test func largeCodeRowUsesBoundedViewportWithoutFloatingFullScreenButton() throws {
        let source = syntheticSwiftSource(lineCount: 180)
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: source,
                language: .swift,
                startLine: 1,
                filePath: "Large.swift"
            ),
            copyOutputText: source,
            toolNamePrefix: "read",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let size = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.isActive)
        #expect(viewportConstraint.constant == 420)
        #expect(size.height < 700, "Large expanded code should stay bounded; got \(size.height)")
        #expect(privateView(named: "expandFloatingButton", in: view) == nil)
    }

    // MARK: - Streaming fixed viewport

    @Test func streamingCodeViewportUsesFixedHeight() throws {
        let source = syntheticSwiftSource(lineCount: 180)
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: source,
                language: .swift,
                startLine: 1,
                filePath: "Streaming.swift"
            ),
            copyOutputText: source,
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.isActive)
        #expect(
            viewportConstraint.constant == ToolTimelineRowContentView.streamingViewportHeight,
            "Streaming code should use fixed viewport height; got \(viewportConstraint.constant)"
        )
    }

    @Test func completedCodeViewportUsesBucketedHeight() throws {
        let source = syntheticSwiftSource(lineCount: 180)
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: source,
                language: .swift,
                startLine: 1,
                filePath: "Done.swift"
            ),
            copyOutputText: source,
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.isActive)
        #expect(
            viewportConstraint.constant == 420,
            "Completed code should use bucketed height; got \(viewportConstraint.constant)"
        )
    }

    @Test func streamingBashOutputUsesFixedViewport() throws {
        let output = (0..<60).map { "line \($0): some output text here" }.joined(separator: "\n")
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "find . -name '*.swift'", output: output, unwrapped: false),
            copyCommandText: "find . -name '*.swift'",
            copyOutputText: output,
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "outputViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.isActive)
        #expect(
            viewportConstraint.constant == ToolTimelineRowContentView.streamingViewportHeight,
            "Streaming bash output should use fixed viewport height; got \(viewportConstraint.constant)"
        )
    }

    @Test func streamingToCompletedTransitionResizesViewport() throws {
        let source = syntheticSwiftSource(lineCount: 100)

        // Start streaming
        let streamingConfig = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: source,
                language: .swift,
                startLine: 1,
                filePath: "Trans.swift"
            ),
            copyOutputText: source,
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: streamingConfig)
        _ = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.constant == ToolTimelineRowContentView.streamingViewportHeight)

        // Transition to done
        let doneConfig = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: source,
                language: .swift,
                startLine: 1,
                filePath: "Trans.swift"
            ),
            copyOutputText: source,
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: true
        )

        view.configuration = doneConfig
        // Force layout to trigger viewport recalculation
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(
            viewportConstraint.constant > ToolTimelineRowContentView.streamingViewportHeight,
            "Completed transition should resize to bucketed height; got \(viewportConstraint.constant)"
        )
    }

    @Test func streamingViewportHeightIsConsistentAcrossContentGrowth() throws {
        // Simulate growing content during streaming — viewport should stay fixed
        let smallSource = syntheticSwiftSource(lineCount: 5)
        let mediumSource = syntheticSwiftSource(lineCount: 40)
        let largeSource = syntheticSwiftSource(lineCount: 150)

        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .code(text: smallSource, language: .swift, startLine: 1, filePath: "Grow.swift"),
            copyOutputText: smallSource,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        let heightAfterSmall = viewportConstraint.constant

        // Grow to medium
        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .code(text: mediumSource, language: .swift, startLine: 1, filePath: "Grow.swift"),
            copyOutputText: mediumSource,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let heightAfterMedium = viewportConstraint.constant

        // Grow to large
        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .code(text: largeSource, language: .swift, startLine: 1, filePath: "Grow.swift"),
            copyOutputText: largeSource,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let heightAfterLarge = viewportConstraint.constant

        #expect(heightAfterSmall == heightAfterMedium, "Viewport height should not change during streaming")
        #expect(heightAfterMedium == heightAfterLarge, "Viewport height should not change during streaming")
        #expect(heightAfterSmall == ToolTimelineRowContentView.streamingViewportHeight)
    }

    private func syntheticSwiftSource(lineCount: Int) -> String {
        (0..<lineCount)
            .map { "func example\($0)() { print(\"line \($0)\") }" }
            .joined(separator: "\n")
    }
}

private func privateView(named name: String, in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIView
}

private func privateConstraint(named name: String, in view: ToolTimelineRowContentView) -> NSLayoutConstraint? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? NSLayoutConstraint
}
