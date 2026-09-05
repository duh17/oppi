import Testing
import UIKit
@testable import Oppi

@Suite("Tool timeline row viewport policy")
@MainActor
struct ToolTimelineRowViewportPolicyTests {
    @Test func expandedContentViewportPoliciesCoverEveryContentType() {
        struct PolicyCase {
            let name: String
            let content: ToolPresentationBuilder.ToolExpandedContent
            let toolNamePrefix: String?
            let expectedSurface: ExpandedRenderOutput.ExpandedSurface
            let expectedMode: ToolTimelineRowContentView.ExpandedViewportMode
            let expectedHeightBehavior: ToolRowViewportPolicy.HeightBehavior
            let expectedPriority: UILayoutPriority
        }

        let videoAttachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "video",
            id: "video-1",
            mimeType: "video/mp4",
            fileName: "demo.mp4",
            sizeBytes: nil,
            width: nil,
            height: nil
        )

        let cases: [PolicyCase] = [
            PolicyCase(
                name: "bash output",
                content: .bash(command: "echo hi", output: "hi", unwrapped: true),
                toolNamePrefix: "$",
                expectedSurface: .label,
                expectedMode: .text,
                expectedHeightBehavior: .cachedMeasured(mode: .output),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "diff",
                content: .diff(lines: [DiffLine(kind: .added, text: "let x = 1")], path: "App.swift"),
                toolNamePrefix: "edit",
                expectedSurface: .label,
                expectedMode: .diff,
                expectedHeightBehavior: .cachedMeasured(mode: .expandedDiff),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "code",
                content: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "App.swift"),
                toolNamePrefix: "read",
                expectedSurface: .label,
                expectedMode: .code,
                expectedHeightBehavior: .cachedMeasured(mode: .expandedCode),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "built-in markdown",
                content: .markdown(text: "# Notes"),
                toolNamePrefix: "read",
                expectedSurface: .markdownViewport,
                expectedMode: .text,
                expectedHeightBehavior: .markdownViewport(maxHeight: ToolTimelineRowContentView.maxOutputViewportHeight),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "extension markdown",
                content: .markdown(text: "# Extension Notes"),
                toolNamePrefix: "extension.notes",
                expectedSurface: .markdownViewport,
                expectedMode: .text,
                expectedHeightBehavior: .markdownViewport(maxHeight: ToolRowViewportPolicy.maxExtensionMarkdownViewportHeight),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "image read media",
                content: .readMedia(output: "data:image/png;base64,abc", filePath: "image.png", startLine: 1, attachments: []),
                toolNamePrefix: "read",
                expectedSurface: .hostedView,
                expectedMode: .text,
                expectedHeightBehavior: .naturalReadMedia(
                    minHeight: ToolTimelineRowContentView.minOutputViewportHeight,
                    maxHeight: ToolRowViewportPolicy.maxNaturalReadMediaHeight
                ),
                expectedPriority: .defaultHigh
            ),
            PolicyCase(
                name: "video read media",
                content: .readMedia(output: "Read video file [video/mp4]", filePath: "demo.mp4", startLine: 1, attachments: [videoAttachment]),
                toolNamePrefix: "read",
                expectedSurface: .compactHostedView,
                expectedMode: .text,
                expectedHeightBehavior: .compactMeasured(minHeight: 1, maxHeight: nil),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "voice read media compatibility",
                content: .readMedia(output: "Voice message", filePath: "Voice message", startLine: 1, attachments: []),
                toolNamePrefix: "voice_speak",
                expectedSurface: .hostedView,
                expectedMode: .text,
                expectedHeightBehavior: .voiceReadMedia(
                    minHeight: ToolRowViewportPolicy.minVoiceReadMediaHeight,
                    maxHeight: ToolRowViewportPolicy.maxVoiceReadMediaHeight
                ),
                expectedPriority: .defaultHigh
            ),
            PolicyCase(
                name: "audio message",
                content: .audioMessage(text: "spoken reply", attachmentId: "audio-1", mimeType: "audio/wav", durationSeconds: 1.0, playbackBehavior: nil),
                toolNamePrefix: "voice_speak",
                expectedSurface: .compactHostedView,
                expectedMode: .text,
                expectedHeightBehavior: .compactMeasured(minHeight: 1, maxHeight: nil),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "status",
                content: .status(message: "Running…"),
                toolNamePrefix: nil,
                expectedSurface: .label,
                expectedMode: .text,
                expectedHeightBehavior: .cachedMeasured(mode: .expandedText),
                expectedPriority: .required
            ),
            PolicyCase(
                name: "text",
                content: .text(text: "plain output", language: nil),
                toolNamePrefix: "extension.notes",
                expectedSurface: .label,
                expectedMode: .text,
                expectedHeightBehavior: .cachedMeasured(mode: .expandedText),
                expectedPriority: .required
            ),
        ]

        for testCase in cases {
            let policy = ToolRowViewportPolicy.forExpandedContent(
                testCase.content,
                toolNamePrefix: testCase.toolNamePrefix
            )
            #expect(policy.surface == testCase.expectedSurface, "Surface mismatch for \(testCase.name)")
            #expect(policy.viewportMode == testCase.expectedMode, "Viewport mode mismatch for \(testCase.name)")
            #expect(policy.heightBehavior == testCase.expectedHeightBehavior, "Height behavior mismatch for \(testCase.name)")
            #expect(policy.constraintPriority == testCase.expectedPriority, "Priority mismatch for \(testCase.name)")
        }
    }

    @Test func readMediaFactsDistinguishConcreteMediaTypes() {
        let imageAttachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "image-1",
            mimeType: "image/png",
            fileName: "preview.png",
            sizeBytes: nil,
            width: nil,
            height: nil
        )
        let videoFacts = ToolRowViewportPolicy.readMediaFacts(
            output: "Read video file [video/mp4]",
            filePath: "clip.mp4",
            attachments: []
        )
        let mixedFacts = ToolRowViewportPolicy.readMediaFacts(
            output: "Read video file [video/mp4]",
            filePath: "clip.mp4",
            attachments: [imageAttachment]
        )
        let svgFacts = ToolRowViewportPolicy.readMediaFacts(
            output: "<svg viewBox=\"0 0 10 10\"></svg>",
            filePath: "chart.svg",
            attachments: []
        )

        #expect(videoFacts.hasVideo)
        #expect(videoFacts.shouldUseCompactVideoLauncher)
        #expect(mixedFacts.hasVideo)
        #expect(mixedFacts.hasImage)
        #expect(!mixedFacts.shouldUseCompactVideoLauncher)
        #expect(svgFacts.hasImage)
        #expect(svgFacts.hasInlineImage)
        #expect(!svgFacts.shouldUseCompactVideoLauncher)
    }

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
        #expect(viewportConstraint.priority == .required)
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

        // outputViewportHeightConstraint is inside BashToolRowView; access directly
        let viewportConstraint = try #require(
            view.bashToolRowView.outputViewportHeightConstraint
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

    @Test func completedMarkdownPublishesSettledViewportBeforeParenting() throws {
        let cases: [(prefix: String, maxHeight: CGFloat)] = [
            ("read", ToolTimelineRowContentView.maxOutputViewportHeight),
            ("x_read", ToolRowViewportPolicy.maxExtensionMarkdownViewportHeight),
        ]
        for item in cases {
            let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
                expandedContent: .markdown(text: "# Notes\n\nBody"),
                toolNamePrefix: item.prefix,
                isExpanded: true,
                isDone: true
            ))
            let viewportConstraint = try #require(
                privateConstraint(named: "expandedViewportHeightConstraint", in: view)
            )
            #expect(
                viewportConstraint.constant == item.maxHeight,
                "Unparented \(item.prefix) must publish the capped viewport, not streaming first-fit; got \(viewportConstraint.constant)"
            )
        }
    }

    @Test func completedMarkdownFittingDoesNotPublishStreamingFirstFit() throws {
        let cell = SafeSizingCell(frame: CGRect(x: 0, y: 0, width: 360, height: 100))
        cell.contentConfiguration = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\nBody"),
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: true
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.size = CGSize(width: 360, height: 100)
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        #expect(
            fitted.size.height > ToolTimelineRowContentView.streamingViewportHeight + 40,
            "First preferred height must not be the streaming first-fit row; got \(fitted.size.height)"
        )
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
