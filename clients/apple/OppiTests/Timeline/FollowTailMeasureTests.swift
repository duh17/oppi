import Testing
import UIKit
@testable import Oppi

@Suite("Follow-tail Core Text measure")
@MainActor
struct FollowTailMeasureTests {
    @Test func unwrappedLongLineDoesNotWrapToViewport() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView()
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.size = CGSize(width: 4_000, height: CGFloat.greatestFiniteMagnitude)
        textView.text = String(repeating: "A", count: 400)
        scrollView.addSubview(textView)

        ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)

        let lineHeight = ceil(textView.font?.lineHeight ?? 16)
        #expect(scrollView.contentSize.height < lineHeight * 3)
        #expect(scrollView.contentSize.height > lineHeight * 0.5)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scrollView))
    }

    @Test func wrappingTextUsesContainerWidth() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView()
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.size = CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)
        textView.text = String(repeating: "word ", count: 80)
        scrollView.addSubview(textView)

        ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)

        let lineHeight = ceil(textView.font?.lineHeight ?? 16)
        #expect(scrollView.contentSize.height > lineHeight * 4)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scrollView))
    }

    @Test func productionCharWrappingUsesContainerWidthNotLineCount() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView(font: ToolFont.regular)
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.size = CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)
        textView.text = String(repeating: "word ", count: 80)
        scrollView.addSubview(textView)

        ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)

        let lineHeight = textView.font?.lineHeight ?? 16
        #expect(scrollView.contentSize.height > lineHeight * 4)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scrollView))
    }

    @Test func trailingNewlineAddsALineOnUnwrappedCode() {
        let withoutTrailing = followTailHeight(
            text: "A\nB",
            lineBreakMode: .byClipping,
            containerWidth: 4_000
        )
        let withTrailing = followTailHeight(
            text: "A\nB\n",
            lineBreakMode: .byClipping,
            containerWidth: 4_000
        )
        let lineHeight = ToolFont.regular.lineHeight
        #expect(withTrailing > withoutTrailing + (lineHeight * 0.5))
        #expect(withTrailing < withoutTrailing + lineHeight + 2)
    }

    @Test func emptyTextStillReportsNearBottom() {
        let prepared = makeFollowTailHarness(
            text: "",
            lineBreakMode: .byClipping,
            containerWidth: 4_000
        )
        ToolTimelineRowUIHelpers.followTail(
            in: prepared.scrollView,
            contentLabel: prepared.textView
        )
        #expect(prepared.scrollView.contentSize.height >= 1)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(prepared.scrollView))
    }

    @Test func unwrappedASCIIHeightMatchesCoreTextMeasure() {
        let text = (1...12).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        assertClippedFollowTailMatchesIndependentGeometry(text: text, containerWidth: 4_000)
    }

    @Test func unwrappedUnicodeAndEmojiStaySingleLineWhenUnwrapped() {
        let text = "你好世界 🎉 café naïve " + String(repeating: "漢", count: 40)
        let height = followTailHeight(
            text: text,
            lineBreakMode: .byClipping,
            containerWidth: 8_000
        )
        let lineHeight = ToolFont.regular.lineHeight
        #expect(height < lineHeight * 2.5)
        #expect(height > lineHeight * 0.5)
    }

    @Test func unwrappedMultilineUnicodeHeightMatchesCoreTextMeasure() {
        let text = (1...8).map {
            "    let value\($0) = \"你好 🎉 café naïve \($0)\""
        }.joined(separator: "\n")
        assertClippedFollowTailMatchesIndependentGeometry(text: text, containerWidth: 8_000)
    }

    @Test func clippedCRLFBareCRAndUnicodeSeparatorsMatchIndependentTextGeometry() {
        let cases: [(name: String, text: String)] = [
            ("LF", "A\nB"),
            ("CRLF", "A\r\nB"),
            ("trailingCRLF", "A\r\nB\r\n"),
            ("trailingCR", "A\r"),
            ("bareCR", "A\rB"),
            ("lineSeparator", "A\u{2028}B"),
            ("paragraphSeparator", "A\u{2029}B"),
        ]
        for item in cases {
            assertClippedFollowTailMatchesIndependentGeometry(
                text: item.text,
                containerWidth: 4_000,
                label: item.name
            )
        }
    }

    @Test func unwrappedUnicode500LinesAvoidsAccumulatedHeightDrift() {
        let text = (1...500).map {
            "    let value\($0) = \"你好 🎉 café naïve \($0)\""
        }.joined(separator: "\n")
        assertClippedFollowTailMatchesIndependentGeometry(text: text, containerWidth: 8_000)
    }

    @Test func mixedFontLaterRunsFallBackToIndependentGeometry() {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: "AAAA\nBBBB\n",
            attributes: [.font: ToolFont.regular]
        ))
        attributed.append(NSAttributedString(
            string: "CCCC\nDDDD",
            attributes: [.font: ToolFont.small]
        ))
        assertClippedFollowTailMatchesIndependentGeometry(
            attributedText: attributed,
            font: ToolFont.regular,
            containerWidth: 4_000,
            label: "mixedFontLaterRuns"
        )
        assertNaiveLineCountDivergesFromIndependentGeometry(
            attributedText: attributed,
            font: ToolFont.regular,
            containerWidth: 4_000,
            expectedLines: 4
        )
    }

    @Test func laterNonzeroParagraphSpacingFallsBackToIndependentGeometry() {
        let string = "AAAA\nBBBB\nCCCC\nDDDD"
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [.font: ToolFont.regular]
        )
        let ns = string as NSString
        var index = 0
        var paragraphIndex = 0
        while index < ns.length {
            var lineEnd = 0
            ns.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: nil,
                for: NSRange(location: index, length: 0)
            )
            if paragraphIndex >= 1 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 24
                attributed.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: index, length: lineEnd - index)
                )
            }
            paragraphIndex += 1
            index = lineEnd
        }
        assertClippedFollowTailMatchesIndependentGeometry(
            attributedText: attributed,
            font: ToolFont.regular,
            containerWidth: 4_000,
            label: "laterParagraphSpacing"
        )
        assertNaiveLineCountDivergesFromIndependentGeometry(
            attributedText: attributed,
            font: ToolFont.regular,
            containerWidth: 4_000,
            expectedLines: 4
        )
    }

    @Test func wrappedUnicodeProseGrowsBeyondLineCount() {
        let text = String(repeating: "你好 🎉 café naïve word ", count: 40)
        let height = followTailHeight(
            text: text,
            lineBreakMode: .byCharWrapping,
            containerWidth: 180
        )
        let lineHeight = ToolFont.regular.lineHeight
        #expect(height > lineHeight * 4)
    }

    @Test func followTailScrollsToBottomForUnicodeWrappedProse() {
        let prepared = makeFollowTailHarness(
            text: String(repeating: "你好 🎉 café naïve word ", count: 40),
            lineBreakMode: .byCharWrapping,
            containerWidth: 180
        )
        ToolTimelineRowUIHelpers.followTail(
            in: prepared.scrollView,
            contentLabel: prepared.textView
        )
        #expect(ToolTimelineRowUIHelpers.isNearBottom(prepared.scrollView))
    }

    private func assertClippedFollowTailMatchesIndependentGeometry(
        text: String,
        containerWidth: CGFloat,
        label: String = ""
    ) {
        let prepared = makeFollowTailHarness(
            text: text,
            lineBreakMode: .byClipping,
            containerWidth: containerWidth
        )
        assertClippedFollowTailMatchesIndependentGeometry(
            prepared: prepared,
            containerWidth: containerWidth,
            label: label.isEmpty ? text : label
        )
    }

    private func assertClippedFollowTailMatchesIndependentGeometry(
        attributedText: NSAttributedString,
        font: UIFont,
        containerWidth: CGFloat,
        label: String
    ) {
        let prepared = makeFollowTailHarness(
            attributedText: attributedText,
            font: font,
            lineBreakMode: .byClipping,
            containerWidth: containerWidth
        )
        assertClippedFollowTailMatchesIndependentGeometry(
            prepared: prepared,
            containerWidth: containerWidth,
            label: label
        )
    }

    private func assertClippedFollowTailMatchesIndependentGeometry(
        prepared: (scrollView: UIScrollView, textView: UITextView),
        containerWidth: CGFloat,
        label: String
    ) {
        ToolTimelineRowUIHelpers.followTail(
            in: prepared.scrollView,
            contentLabel: prepared.textView
        )
        let followHeight = prepared.scrollView.contentSize.height
        let coreTextHeight = coreTextContentHeight(
            of: prepared.textView,
            containerWidth: containerWidth
        )
        let textKitHeight = textKitSizeThatFitsHeight(
            of: prepared.textView,
            containerWidth: containerWidth
        )
        #expect(
            abs(followHeight - coreTextHeight) <= 2,
            "\(label): followTail=\(followHeight) coreText=\(coreTextHeight) textKit=\(textKitHeight)"
        )
        #expect(
            abs(followHeight - textKitHeight) <= 2,
            "\(label): followTail=\(followHeight) coreText=\(coreTextHeight) textKit=\(textKitHeight)"
        )
    }

    private func assertNaiveLineCountDivergesFromIndependentGeometry(
        attributedText: NSAttributedString,
        font: UIFont,
        containerWidth: CGFloat,
        expectedLines: Int
    ) {
        let prepared = makeFollowTailHarness(
            attributedText: attributedText,
            font: font,
            lineBreakMode: .byClipping,
            containerWidth: containerWidth
        )
        let naiveHeight = ceil(CGFloat(expectedLines) * font.lineHeight)
            + prepared.textView.textContainerInset.top
            + prepared.textView.textContainerInset.bottom
        let coreTextHeight = coreTextContentHeight(
            of: prepared.textView,
            containerWidth: containerWidth
        )
        #expect(
            abs(coreTextHeight - naiveHeight) > 2,
            "fixture must diverge from uniform line-count: naive=\(naiveHeight) coreText=\(coreTextHeight)"
        )
    }

    private func coreTextContentHeight(
        of textView: UITextView,
        containerWidth: CGFloat
    ) -> CGFloat {
        let inset = textView.textContainerInset
        let text = textView.attributedText ?? NSAttributedString()
        guard text.length > 0 else {
            return max(1, inset.top + inset.bottom)
        }
        let rect = text.boundingRect(
            with: CGSize(width: containerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height) + inset.top + inset.bottom
    }

    private func textKitSizeThatFitsHeight(
        of textView: UITextView,
        containerWidth: CGFloat
    ) -> CGFloat {
        let oracle = UITextView(
            frame: CGRect(x: 0, y: 0, width: containerWidth, height: 8)
        )
        oracle.isScrollEnabled = false
        oracle.textContainerInset = textView.textContainerInset
        oracle.textContainer.lineFragmentPadding = textView.textContainer.lineFragmentPadding
        oracle.textContainer.lineBreakMode = textView.textContainer.lineBreakMode
        oracle.textContainer.size = CGSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        oracle.font = textView.font
        oracle.attributedText = textView.attributedText
        return oracle.sizeThatFits(
            CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height
    }

    private func followTailHeight(
        text: String,
        lineBreakMode: NSLineBreakMode,
        containerWidth: CGFloat
    ) -> CGFloat {
        let prepared = makeFollowTailHarness(
            text: text,
            lineBreakMode: lineBreakMode,
            containerWidth: containerWidth
        )
        ToolTimelineRowUIHelpers.followTail(
            in: prepared.scrollView,
            contentLabel: prepared.textView
        )
        return prepared.scrollView.contentSize.height
    }

    private func makeFollowTailHarness(
        text: String,
        lineBreakMode: NSLineBreakMode,
        containerWidth: CGFloat
    ) -> (scrollView: UIScrollView, textView: UITextView) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView(font: ToolFont.regular)
        textView.textContainer.lineBreakMode = lineBreakMode
        textView.textContainer.size = CGSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.text = text
        scrollView.addSubview(textView)
        return (scrollView, textView)
    }

    private func makeFollowTailHarness(
        attributedText: NSAttributedString,
        font: UIFont,
        lineBreakMode: NSLineBreakMode,
        containerWidth: CGFloat
    ) -> (scrollView: UIScrollView, textView: UITextView) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView(font: font)
        textView.textContainer.lineBreakMode = lineBreakMode
        textView.textContainer.size = CGSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = font
        textView.attributedText = attributedText
        scrollView.addSubview(textView)
        return (scrollView, textView)
    }

    private func makeExpandedTextView(font: UIFont? = nil) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return textView
    }
}

@Suite("Follow-tail expanded tool apply")
@MainActor
struct FollowTailExpandedToolApplyTests {
    private struct WindowedToolHarness {
        let window: UIWindow
        let view: ToolTimelineRowContentView
    }

    @Test func unwrappedStreamingApplyFollowsTail() {
        let harness = makeWindowedToolView(text: "import Foundation\n", language: .swift)
        applyStreaming(harness.view, text: generateSwiftCode(lines: 60), language: .swift)

        #expect(harness.view.window === harness.window)
        #expect(harness.view.expandedShouldAutoFollow)
        #expect(harness.view.expandedScrollView.bounds.height > 0)
        #expect(
            harness.view.expandedScrollView.contentSize.height
                > harness.view.expandedScrollView.bounds.height
        )
        assertFinalRowVisibleAgainstIndependentGeometry(harness.view)
    }

    @Test func wrappedStreamingApplyFollowsTail() {
        let harness = makeWindowedToolView(text: "line 1\n", language: nil)
        applyStreaming(harness.view, text: generateWrappedProse(lines: 60), language: nil)

        #expect(harness.view.window === harness.window)
        #expect(harness.view.expandedShouldAutoFollow)
        assertFinalRowVisibleAgainstIndependentGeometry(harness.view)
    }

    @Test func unicodeAndTrailingNewlinesFollowTail() {
        let harness = makeWindowedToolView(text: "start 你好\n", language: .swift)
        applyStreaming(harness.view, text: generateUnicodeCode(lines: 48) + "\n", language: .swift)

        #expect(harness.view.window === harness.window)
        #expect(harness.view.expandedShouldAutoFollow)
        assertFinalRowVisibleAgainstIndependentGeometry(harness.view)
    }

    @Test func crlfStreamingApplyShowsFinalRowAgainstIndependentGeometry() {
        let harness = makeWindowedToolView(
            text: "import Foundation\r\n",
            language: .swift
        )
        applyStreaming(
            harness.view,
            text: generateSwiftCode(lines: 60, separator: "\r\n"),
            language: .swift
        )

        #expect(harness.view.window === harness.window)
        #expect(harness.view.expandedShouldAutoFollow)
        assertFinalRowVisibleAgainstIndependentGeometry(harness.view)
        writeStreamingTailArtifactIfRequested(
            named: "follow-tail-streaming-final-row",
            from: harness.view
        )
    }

    @Test func detachedStreamingApplyPreservesViewport() {
        let harness = makeWindowedToolView(
            text: generateSwiftCode(lines: 60),
            language: .swift
        )
        let view = harness.view
        let scrollView = view.expandedScrollView
        #expect(view.window === harness.window)
        assertFinalRowVisibleAgainstIndependentGeometry(view)

        let inset = scrollView.adjustedContentInset
        let detachedOffset = CGPoint(x: -inset.left, y: -inset.top)
        view.expandedShouldAutoFollow = false
        scrollView.setContentOffset(detachedOffset, animated: false)
        #expect(!ToolTimelineRowUIHelpers.isNearBottom(scrollView))

        applyStreaming(view, text: generateSwiftCode(lines: 90), language: .swift)

        #expect(view.window === harness.window)
        #expect(!view.expandedShouldAutoFollow)
        #expect(
            !ToolTimelineRowUIHelpers.isNearBottom(scrollView),
            "Detached streaming must not jump back to the tail"
        )
        #expect(abs(scrollView.contentOffset.y - detachedOffset.y) <= 1)
    }

    private func makeWindowedToolView(
        text: String,
        language: SyntaxLanguage?
    ) -> WindowedToolHarness {
        let view = ToolTimelineRowContentView(
            configuration: makeStreamingToolConfiguration(text: text, language: language)
        )
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.makeKeyAndVisible()
        forceLayout(view)
        return WindowedToolHarness(window: window, view: view)
    }

    private func applyStreaming(
        _ view: ToolTimelineRowContentView,
        text: String,
        language: SyntaxLanguage?
    ) {
        view.configuration = makeStreamingToolConfiguration(text: text, language: language)
        forceLayout(view)
    }

    private func makeStreamingToolConfiguration(
        text: String,
        language: SyntaxLanguage?
    ) -> ToolTimelineRowConfiguration {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(
                text: text,
                language: language,
                startLine: 1,
                filePath: "Test.swift"
            )
        } else {
            expandedContent = .text(text: text, language: nil)
        }
        return makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
    }

    private func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func assertFinalRowVisibleAgainstIndependentGeometry(
        _ view: ToolTimelineRowContentView
    ) {
        #expect(view.window != nil)
        let scrollView = view.expandedScrollView
        let independentHeight = independentContentHeight(of: view.expandedLabel)
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        #expect(viewportHeight > 0)
        #expect(independentHeight > viewportHeight)
        let bottomY = scrollView.contentOffset.y + inset.top + viewportHeight
        let distance = max(0, independentHeight - bottomY)
        print(
            "OPPI_FOLLOW_TAIL_VIEWPORT offsetY=\(scrollView.contentOffset.y) contentHeight=\(scrollView.contentSize.height) boundsHeight=\(scrollView.bounds.height) independentHeight=\(independentHeight) distance=\(distance)"
        )
        #expect(
            distance <= 18,
            "final independent row must be visible, distance=\(distance) independent=\(independentHeight) bottomY=\(bottomY) contentSize=\(scrollView.contentSize.height)"
        )
    }

    private func independentContentHeight(of textView: UITextView) -> CGFloat {
        let inset = textView.textContainerInset
        let text = textView.attributedText ?? NSAttributedString()
        guard text.length > 0 else {
            return max(1, inset.top + inset.bottom)
        }
        let padding = textView.textContainer.lineFragmentPadding
        let containerWidth = textView.textContainer.size.width
        let width: CGFloat
        if containerWidth > 1, containerWidth.isFinite {
            width = containerWidth
        } else {
            width = max(1, textView.bounds.width - inset.left - inset.right - (padding * 2))
        }
        let rect = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height) + inset.top + inset.bottom
    }

    private func writeStreamingTailArtifactIfRequested(
        named name: String,
        from view: ToolTimelineRowContentView
    ) {
        guard let directory = ProcessInfo.processInfo.environment["OPPI_FOLLOW_TAIL_ARTIFACT_DIR"],
              !directory.isEmpty else {
            return
        }
        let scrollView = view.expandedScrollView
        let bounds = scrollView.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            Issue.record("Streaming tail artifact skipped: empty scroll view bounds")
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { _ in
            scrollView.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            Issue.record("Streaming tail artifact PNG encode failed")
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("OPPI_FOLLOW_TAIL_ARTIFACT=\(url.path)")
        } catch {
            Issue.record("Streaming tail artifact write failed: \(error)")
        }
    }

    private func generateSwiftCode(lines: Int, separator: String = "\n") -> String {
        (1...max(1, lines)).map { "    let value\($0) = \($0) // line \($0)" }
            .joined(separator: separator)
    }

    private func generateWrappedProse(lines: Int) -> String {
        (1...max(1, lines)).map {
            "The quick brown fox jumps over the lazy dog in paragraph \($0) with enough words to wrap."
        }
        .joined(separator: "\n")
    }

    private func generateUnicodeCode(lines: Int) -> String {
        (1...max(1, lines)).map { "    let value\($0) = \"你好 🎉 café naïve \($0)\"" }
            .joined(separator: "\n")
    }
}
