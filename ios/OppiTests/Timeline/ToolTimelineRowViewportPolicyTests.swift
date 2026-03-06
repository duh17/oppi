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
