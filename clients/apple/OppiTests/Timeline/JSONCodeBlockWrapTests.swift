import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
private struct JSONCodeBlockFixture {
    let codeBlock: NativeCodeBlockView
    let scrollView: UIScrollView
    let textView: UITextView
    let wrapControl: UIButton
}

@MainActor
@Suite("JSON code block wrap")
struct JSONCodeBlockWrapTests {
    private let compactJSON = #"{"ok":true,"data":{"timed_out":true}}"#

    @Test func wrapOnPrettyPrintsValidJSONFence() throws {
        let fixture = try makeJSONCodeBlock(code: compactJSON)

        #expect(displayedCode(in: fixture.textView) == compactJSON)
        #expect(fixture.textView.textContainer.lineBreakMode == .byClipping)
        #expect(fixture.wrapControl.accessibilityLabel == "Wrap code lines")
        #expect(fixture.wrapControl.accessibilityValue == "Off")

        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)

        let displayed = displayedCode(in: fixture.textView)
        #expect(displayed != compactJSON)
        #expect(displayed.contains("\n"))
        #expect(displayed.contains("  "))
        let dataKey = try #require(displayed.range(of: "\"data\""))
        let okKey = try #require(displayed.range(of: "\"ok\""))
        #expect(dataKey.lowerBound < okKey.lowerBound)
        #expect(fixture.textView.textContainer.lineBreakMode == .byCharWrapping)
        #expect(!fixture.scrollView.isScrollEnabled)
        #expect(fixture.wrapControl.accessibilityLabel == "Unwrap code lines")
        #expect(fixture.wrapControl.accessibilityValue == "On")
        #expect(fixture.wrapControl.configuration?.title == nil)
        #expect(fixture.wrapControl.configuration?.image != nil)
    }

    @Test func wrapOffRestoresOriginalCompactSource() throws {
        let fixture = try makeJSONCodeBlock(code: compactJSON)

        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)
        #expect(displayedCode(in: fixture.textView) != compactJSON)

        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)

        #expect(displayedCode(in: fixture.textView) == compactJSON)
        #expect(fixture.textView.textContainer.lineBreakMode == .byClipping)
        #expect(fixture.scrollView.isScrollEnabled)
        #expect(fixture.scrollView.contentSize.width > fixture.scrollView.frame.width)
        #expect(fixture.wrapControl.accessibilityLabel == "Wrap code lines")
        #expect(fixture.wrapControl.accessibilityValue == "Off")
    }

    @Test func leftoverLongLinesStillWrapAfterPrettyPrint() throws {
        let longValue = String(repeating: "very-long-json-value-", count: 20)
        let source = #"{"ok":true,"note":"\#(longValue)"}"#
        let fixture = try makeJSONCodeBlock(code: source)

        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)

        let displayed = displayedCode(in: fixture.textView)
        #expect(displayed.contains("\n"))
        #expect(displayed.contains(longValue))
        #expect(fixture.textView.textContainer.lineBreakMode == .byCharWrapping)
        #expect(!fixture.scrollView.isScrollEnabled)
        #expect(fixture.scrollView.contentSize.width <= fixture.scrollView.frame.width + 1)
        #expect(abs(fixture.scrollView.contentOffset.x) < 0.5)
    }

    @Test func copyCopiesOriginalSourceWhilePrettyDisplayed() throws {
        let fixture = try makeJSONCodeBlock(code: compactJSON)
        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)
        #expect(displayedCode(in: fixture.textView) != compactJSON)

        UIPasteboard.general.string = "sentinel-before-copy"
        let copyControl = try #require(findCopyControl(in: fixture.codeBlock))
        copyControl.sendActions(for: .touchUpInside)

        #expect(UIPasteboard.general.string == compactJSON)
        #expect(displayedCode(in: fixture.textView) != compactJSON)
    }

    @Test func doesNotPrettyPrintWhenWrapIsOff() throws {
        let fixture = try makeJSONCodeBlock(code: compactJSON)

        #expect(displayedCode(in: fixture.textView) == compactJSON)
        #expect(fixture.textView.textContainer.lineBreakMode == .byClipping)
        #expect(fixture.scrollView.contentSize.width > fixture.scrollView.frame.width)
        #expect(fixture.wrapControl.accessibilityValue == "Off")
    }

    @Test func jsonlAndJsoncFencesDoNotPrettyPrint() throws {
        for language in ["jsonl", "jsonc"] {
            let fixture = try makeCodeBlock(language: language, code: compactJSON)
            fixture.wrapControl.sendActions(for: .touchUpInside)
            layout(fixture)

            #expect(displayedCode(in: fixture.textView) == compactJSON, "\(language) should not pretty-print")
            #expect(fixture.textView.textContainer.lineBreakMode == .byCharWrapping)
            #expect(!fixture.scrollView.isScrollEnabled)
        }
    }

    @Test func invalidJSONOnlySoftWraps() throws {
        let invalid = #"{"ok": true, "data": { "timed_out": true,"#
        let fixture = try makeJSONCodeBlock(code: invalid)

        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)

        #expect(displayedCode(in: fixture.textView) == invalid)
        #expect(fixture.textView.textContainer.lineBreakMode == .byCharWrapping)
        #expect(!fixture.scrollView.isScrollEnabled)
    }

    @Test func uppercaseJSONFencePrettyPrints() throws {
        let fixture = try makeCodeBlock(language: "JSON", code: compactJSON)
        fixture.wrapControl.sendActions(for: .touchUpInside)
        layout(fixture)

        let displayed = displayedCode(in: fixture.textView)
        #expect(displayed != compactJSON)
        #expect(displayed.contains("\n"))
    }

    @Test func wrapAlreadyOnPrettyPrintsWhenStreamingBecomesValid() throws {
        let view = NativeCodeBlockView()
        let palette = ThemePalettes.dark
        view.apply(language: "json", code: #"{ "ok": tru"#, palette: palette, isOpen: true, themeID: .dark)
        _ = fit(view)

        let wrapControl = try #require(findWrapControl(in: view))
        wrapControl.sendActions(for: .touchUpInside)
        layout(view)
        #expect(displayedCode(in: view) == #"{ "ok": tru"#)

        view.apply(
            language: "json",
            code: compactJSON,
            palette: palette,
            isOpen: false,
            themeID: .dark
        )
        layout(view)

        let displayed = displayedCode(in: view)
        #expect(displayed != compactJSON)
        #expect(displayed.contains("\n"))
        #expect(displayed.contains("  "))
    }

    @Test func timelineRemeasuresWhenWrapOnJSONFenceBecomesValid() async throws {
        let incompleteJSON = #"{ "ok": tru"#
        let wh = makeWindowedTimelineHarness(
            sessionId: "json-wrap-pretty-remeasure",
            frame: CGRect(x: 0, y: 0, width: 390, height: 1_200),
            useAnchoredCollectionView: true
        )
        wh.applyItems(
            [
                .assistantMessage(
                    id: "assistant-json",
                    text: "```json\n\(incompleteJSON)",
                    timestamp: Date(timeIntervalSince1970: 0)
                ),
                .userMessage(
                    id: "user-after",
                    text: "Keep going.",
                    timestamp: Date(timeIntervalSince1970: 1)
                ),
            ],
            isBusy: true,
            streamingID: "assistant-json"
        )

        let firstIP = IndexPath(item: 0, section: 0)
        let secondIP = IndexPath(item: 1, section: 0)
        let anchoredCollectionView = try #require(wh.collectionView as? AnchoredCollectionView)
        anchoredCollectionView.isDetachedFromBottom = true
        anchoredCollectionView.captureDetachedAnchor()
        #expect(anchoredCollectionView.detachedAnchorIsActive)

        let firstCell = try #require(wh.collectionView.cellForItem(at: firstIP))
        let codeBlock = try #require(
            timelineFirstView(ofType: NativeCodeBlockView.self, in: firstCell.contentView)
        )
        let wrapButton = try #require(findWrapControl(in: codeBlock))
        wrapButton.sendActions(for: .touchUpInside)
        wh.collectionView.layoutIfNeeded()
        #expect(displayedCode(in: codeBlock) == incompleteJSON)

        let heightAfterWrap = try #require(
            wh.collectionView.layoutAttributesForItem(at: firstIP)?.frame.height
        )

        codeBlock.apply(
            language: "json",
            code: compactJSON,
            palette: ThemeRuntimeState.currentPalette(),
            isOpen: false,
            themeID: ThemeRuntimeState.currentThemeID()
        )

        let reflowed = await waitForTimelineCondition(timeoutMs: 800) {
            await MainActor.run {
                wh.collectionView.layoutIfNeeded()
                guard let firstFrame = wh.collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                      let secondFrame = wh.collectionView.layoutAttributesForItem(at: secondIP)?.frame else {
                    return false
                }
                return firstFrame.height > heightAfterWrap + 40
                    && secondFrame.minY >= firstFrame.maxY - 0.5
            }
        }

        let finalFrames = await MainActor.run {
            (
                wh.collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                wh.collectionView.layoutAttributesForItem(at: secondIP)?.frame
            )
        }
        let textView = try #require(
            timelineAllTextViews(in: codeBlock).first {
                $0.accessibilityIdentifier == "markdown.codeBlock.text"
            }
        )
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let textUsedHeight = ceil(textView.layoutManager.usedRect(for: textView.textContainer).height)
        let displayed = displayedCode(in: textView)

        #expect(displayed != compactJSON)
        #expect(displayed.contains("\n"))
        #expect(
            reflowed,
            Comment(rawValue: "Timeline did not remeasure after wrap-on JSON pretty-print "
                + "(height after wrap: \(heightAfterWrap), "
                + "final first: \(String(describing: finalFrames.0)), "
                + "final second: \(String(describing: finalFrames.1)))")
        )
        #expect(
            textView.bounds.height >= textUsedHeight - 1,
            "Pretty-printed JSON is clipped (bounds: \(textView.bounds.height), used: \(textUsedHeight))"
        )
    }

    @Test func originalHighlightIsCachedButNotPaintedOverPrettyText() async throws {
        let view = NativeCodeBlockView()
        let palette = ThemePalettes.dark
        let identity = SyntaxHighlightIdentity(code: compactJSON, language: "json", themeID: .dark)
        view.apply(language: "json", code: compactJSON, palette: palette, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(compactJSON, language: .json, themeID: .dark),
            identity: identity
        )
        #expect(view.hasCurrentHighlight)
        #expect(displayedCode(in: view) == compactJSON)

        let wrapControl = try #require(findWrapControl(in: view))
        wrapControl.sendActions(for: .touchUpInside)
        layout(view)

        #expect(view.hasCurrentHighlight)
        #expect(displayedCode(in: view) != compactJSON)
        #expect(displayedCode(in: view).contains("\n"))

        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(compactJSON, language: .json, themeID: .dark),
            identity: identity
        )
        #expect(view.hasCurrentHighlight)
        #expect(displayedCode(in: view) != compactJSON)
        #expect(displayedCode(in: view).contains("\n"))

        let colored = await waitForMainActorCondition(timeout: .seconds(2)) {
            uniqueForegroundColorCount(codeAttributedText(in: view) ?? NSAttributedString()) >= 2
                && (codeAttributedText(in: view)?.string.contains("\n") == true)
        }
        #expect(colored)
        #expect(codeAttributedText(in: view)?.string != compactJSON)
    }

    @Test func wrapOffRestoresOriginalHighlightedSource() throws {
        let view = NativeCodeBlockView()
        let identity = SyntaxHighlightIdentity(code: compactJSON, language: "json", themeID: .dark)
        view.apply(language: "json", code: compactJSON, palette: ThemePalettes.dark, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(compactJSON, language: .json, themeID: .dark),
            identity: identity
        )

        let wrapControl = try #require(findWrapControl(in: view))
        wrapControl.sendActions(for: .touchUpInside)
        wrapControl.sendActions(for: .touchUpInside)
        layout(view)

        #expect(displayedCode(in: view) == compactJSON)
        #expect(view.hasCurrentHighlight)
        let attributed = try #require(codeAttributedText(in: view))
        #expect(attributed.string == compactJSON)
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }
}

@MainActor
private func makeJSONCodeBlock(code: String) throws -> JSONCodeBlockFixture {
    try makeCodeBlock(language: "json", code: code)
}

@MainActor
private func makeCodeBlock(language: String, code: String) throws -> JSONCodeBlockFixture {
    let markdown = AssistantMarkdownContentView()
    markdown.apply(configuration: .make(
        content: "```\(language)\n\(code)\n```",
        isStreaming: false,
        themeID: ThemeRuntimeState.currentThemeID()
    ))
    _ = fittedTimelineSize(for: markdown, width: 300)

    let codeBlock = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
    let scrollView = try #require(timelineAllScrollViews(in: codeBlock).first)
    let textView = try #require(
        timelineAllTextViews(in: scrollView).first {
            $0.accessibilityIdentifier == "markdown.codeBlock.text"
        }
    )
    let wrapControl = try #require(findWrapControl(in: codeBlock))
    codeBlock.layoutIfNeeded()
    return JSONCodeBlockFixture(
        codeBlock: codeBlock,
        scrollView: scrollView,
        textView: textView,
        wrapControl: wrapControl
    )
}

@MainActor
private func findWrapControl(in view: UIView) -> UIButton? {
    timelineAllViews(in: view)
        .compactMap { $0 as? UIButton }
        .first { $0.accessibilityIdentifier == "markdown.codeBlock.wrap" }
}

@MainActor
private func findCopyControl(in view: UIView) -> UIButton? {
    timelineAllViews(in: view)
        .compactMap { $0 as? UIButton }
        .first { $0.accessibilityIdentifier != "markdown.codeBlock.wrap" }
}

@MainActor
private func displayedCode(in textView: UITextView) -> String {
    textView.attributedText?.string ?? textView.text ?? ""
}

@MainActor
private func displayedCode(in root: UIView) -> String {
    if let labeled = timelineAllTextViews(in: root).first(where: {
        $0.accessibilityIdentifier == "markdown.codeBlock.text"
    }) {
        return displayedCode(in: labeled)
    }
    return timelineAllTextViews(in: root).first.map(displayedCode) ?? ""
}

@MainActor
private func codeAttributedText(in root: UIView) -> NSAttributedString? {
    timelineAllTextViews(in: root).first {
        $0.accessibilityIdentifier == "markdown.codeBlock.text"
    }?.attributedText ?? timelineAllTextViews(in: root).first?.attributedText
}

@MainActor
private func layout(_ fixture: JSONCodeBlockFixture) {
    layout(fixture.codeBlock, scrollView: fixture.scrollView)
}

@MainActor
private func layout(_ codeBlock: UIView, scrollView: UIScrollView? = nil) {
    codeBlock.setNeedsLayout()
    codeBlock.layoutIfNeeded()
    scrollView?.layoutIfNeeded()
}

@MainActor
private func fit(_ view: NativeCodeBlockView) -> CGSize {
    fittedTimelineSize(for: view, width: 300)
}

private func uniqueForegroundColorCount(_ attributed: NSAttributedString) -> Int {
    var colors: [UIColor] = []
    attributed.enumerateAttribute(
        .foregroundColor,
        in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        guard let color = value as? UIColor else { return }
        if !colors.contains(where: { $0.isEqual(color) }) {
            colors.append(color)
        }
    }
    return colors.count
}
