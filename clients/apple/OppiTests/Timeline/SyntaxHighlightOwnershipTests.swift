import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Syntax highlight ownership")
struct SyntaxHighlightOwnershipTests {

    // MARK: - NativeCodeBlockView

    @Test func codeBlockDoesNotInstallStaleHighlightAfterCodeReplacement() throws {
        let view = NativeCodeBlockView()
        let palette = ThemePalettes.dark
        let codeA = "let alphaUnique = 1"
        let codeB = "let betaUnique = 2"
        let identityA = SyntaxHighlightIdentity(code: codeA, language: "swift", themeID: .dark)

        view.apply(language: "swift", code: codeA, palette: palette, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(codeA, language: .swift, themeID: .dark),
            identity: identityA
        )
        #expect(codeText(in: view).contains("alphaUnique"))

        view.apply(language: "swift", code: codeB, palette: palette, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(codeA, language: .swift, themeID: .dark),
            identity: identityA
        )

        let displayed = codeText(in: view)
        #expect(displayed.contains("betaUnique"))
        #expect(!displayed.contains("alphaUnique"))
    }

    @Test func codeBlockChromeRefreshDoesNotFlattenHighlightColors() throws {
        let view = NativeCodeBlockView()
        let code = "let value = \"hello\""
        let identity = SyntaxHighlightIdentity(code: code, language: "swift", themeID: .dark)
        view.apply(language: "swift", code: code, palette: ThemePalettes.dark, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(
            SyntaxHighlighter.highlight(code, language: .swift, themeID: .dark),
            identity: identity
        )

        let highlighted = try #require(codeAttributedText(in: view))
        #expect(uniqueForegroundColorCount(highlighted) >= 2)

        view.apply(language: "swift", code: code, palette: ThemePalettes.light, isOpen: false, themeID: .dark)
        let after = try #require(codeAttributedText(in: view))
        #expect(uniqueForegroundColorCount(after) >= 2)
        #expect(after.string.contains("hello"))
    }

    @Test func codeBlockDoesNotInstallStaleHighlightAfterLanguageChangeWithSameCode() throws {
        let view = NativeCodeBlockView()
        let palette = ThemePalettes.dark
        let code = "let value = 1"
        let swiftIdentity = SyntaxHighlightIdentity(code: code, language: "swift", themeID: .dark)
        let swiftPaint = SyntaxHighlighter.highlight(code, language: .swift, themeID: .dark)

        view.apply(language: "swift", code: code, palette: palette, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(swiftPaint, identity: swiftIdentity)
        #expect(view.hasCurrentHighlight)

        view.apply(language: "python", code: code, palette: palette, isOpen: false, themeID: .dark)
        #expect(!view.hasCurrentHighlight)

        view.applyHighlightedCode(swiftPaint, identity: swiftIdentity)

        #expect(!view.hasCurrentHighlight)
        #expect(codeText(in: view).contains("let value"))
    }

    @Test func codeBlockDoesNotInstallStaleHighlightAfterThemeChangeWithSameCode() throws {
        let view = NativeCodeBlockView()
        let code = "let value = 1"
        let darkIdentity = SyntaxHighlightIdentity(code: code, language: "swift", themeID: .dark)
        let darkPaint = SyntaxHighlighter.highlight(code, language: .swift, themeID: .dark)

        view.apply(language: "swift", code: code, palette: ThemePalettes.dark, isOpen: false, themeID: .dark)
        view.applyHighlightedCode(darkPaint, identity: darkIdentity)
        #expect(view.hasCurrentHighlight)

        view.apply(language: "swift", code: code, palette: ThemePalettes.light, isOpen: false, themeID: .light)
        #expect(!view.hasCurrentHighlight)

        view.applyHighlightedCode(darkPaint, identity: darkIdentity)

        #expect(!view.hasCurrentHighlight)
        let displayed = try #require(codeAttributedText(in: view))
        #expect(displayed.string.contains("let value"))
        #expect(
            foregroundColor(of: "let", in: displayed) != UIColor(ThemePalettes.light.syntaxKeyword)
        )
    }

    // MARK: - Markdown applier identity

    @Test func delayedMarkdownHighlightDoesNotInstallOntoReplacedCode() async throws {
        AssistantMarkdownSegmentApplier.highlightDelayForTesting = .milliseconds(180)
        defer { AssistantMarkdownSegmentApplier.highlightDelayForTesting = nil }

        let markdown = AssistantMarkdownContentView()
        markdown.apply(configuration: .make(
            content: fence("swift", "let alphaUnique = 1"),
            isStreaming: false,
            themeID: .dark
        ))
        let codeView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))

        markdown.apply(configuration: .make(
            content: fence("swift", "let betaUnique = 2"),
            isStreaming: false,
            themeID: .dark
        ))
        #expect(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown) === codeView)

        try await waitUntil(timeout: .seconds(2)) {
            codeText(in: codeView).contains("betaUnique")
                && uniqueForegroundColorCount(codeAttributedText(in: codeView) ?? NSAttributedString()) >= 2
        }

        let displayed = codeText(in: codeView)
        #expect(displayed.contains("betaUnique"))
        #expect(!displayed.contains("alphaUnique"))
        let attributed = try #require(codeAttributedText(in: codeView))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
        #expect(
            foregroundColor(of: "let", in: attributed) == UIColor(ThemePalettes.dark.syntaxKeyword)
        )
    }

    @Test func delayedMarkdownHighlightInstallsCurrentThemeAfterReplacementAndThemeSwitch() async throws {
        AssistantMarkdownSegmentApplier.highlightDelayForTesting = .milliseconds(180)
        defer { AssistantMarkdownSegmentApplier.highlightDelayForTesting = nil }

        let originalTheme = ThemeRuntimeState.currentThemeID()
        ThemeRuntimeState.setThemeID(.dark)
        defer { ThemeRuntimeState.setThemeID(originalTheme) }

        let markdown = AssistantMarkdownContentView()
        markdown.apply(configuration: .make(
            content: fence("swift", "let alphaUnique = 1"),
            isStreaming: false,
            themeID: .dark
        ))

        markdown.apply(configuration: .make(
            content: fence("swift", "let betaUnique = 2"),
            isStreaming: false,
            themeID: .dark
        ))

        ThemeRuntimeState.setThemeID(.light)
        markdown.apply(configuration: .make(
            content: fence("swift", "let betaUnique = 2"),
            isStreaming: false,
            themeID: .light
        ))

        let codeView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
        try await waitUntil(timeout: .seconds(2)) {
            codeText(in: codeView).contains("betaUnique")
                && foregroundColor(of: "let", in: codeAttributedText(in: codeView) ?? NSAttributedString())
                    == UIColor(ThemePalettes.light.syntaxKeyword)
        }

        let attributed = try #require(codeAttributedText(in: codeView))
        #expect(attributed.string.contains("betaUnique"))
        #expect(!attributed.string.contains("alphaUnique"))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
        #expect(foregroundColor(of: "let", in: attributed) == UIColor(ThemePalettes.light.syntaxKeyword))
    }

    @Test func unchangedMarkdownReconfigureDoesNotRedoHighlightWork() async throws {
        let markdown = AssistantMarkdownContentView()
        markdown.apply(configuration: .make(
            content: fence("swift", "let value = 1"),
            isStreaming: false,
            themeID: .dark,
            textSelectionEnabled: true
        ))
        let codeView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
        try await waitUntil(timeout: .seconds(2)) {
            codeView.debugHasHighlightedTextForTesting
        }
        let workAfterFirst = markdown.debugHighlightWorkCountForTesting
        #expect(workAfterFirst >= 1)

        markdown.debugClearHighlightTasksForTesting()
        markdown.apply(configuration: .make(
            content: fence("swift", "let value = 1"),
            isStreaming: false,
            themeID: .dark,
            textSelectionEnabled: false
        ))

        #expect(markdown.debugHighlightWorkCountForTesting == workAfterFirst)
        let attributed = try #require(codeAttributedText(in: codeView))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }

    // MARK: - Fullscreen

    @Test func fullscreenPaletteRefreshDoesNotFlattenHighlightColors() async throws {
        NativeFullScreenCodeBody.highlightDelayForTesting = .milliseconds(180)
        defer { NativeFullScreenCodeBody.highlightDelayForTesting = nil }

        let body = makeFullScreenCodeBody(content: "let value = \"hello\"", themeID: .dark)
        NativeFullScreenCodeBody.highlightDelayForTesting = nil
        try await waitUntil(timeout: .seconds(2)) {
            uniqueForegroundColorCount(codeAttributedText(in: body) ?? NSAttributedString()) >= 2
        }
        #expect(uniqueForegroundColorCount(try #require(codeAttributedText(in: body))) >= 2)

        NativeFullScreenCodeBody.highlightDelayForTesting = .milliseconds(180)
        body.applyPalette(ThemePalettes.light, themeID: .light)
        let afterChrome = try #require(codeAttributedText(in: body))
        #expect(uniqueForegroundColorCount(afterChrome) >= 2)
        #expect(afterChrome.string.contains("hello"))
    }

    @Test func fullscreenUnchangedPaletteDoesNotRedoHighlightWork() async throws {
        let body = makeFullScreenCodeBody(content: "let value = 1", themeID: .dark)
        try await waitUntil(timeout: .seconds(2)) {
            uniqueForegroundColorCount(codeAttributedText(in: body) ?? NSAttributedString()) >= 2
        }
        let workAfterFirst = body.debugHighlightWorkCountForTesting
        #expect(workAfterFirst >= 1)

        body.applyPalette(ThemePalettes.dark, themeID: .dark)
        #expect(body.debugHighlightWorkCountForTesting == workAfterFirst)
    }

    // MARK: - Deferred tool cache

    @Test func deferredCodeHighlightDoesNotCacheWhenNoLongerCurrent() async throws {
        ToolRowRenderCache.evictAll()
        ToolTimelineRowContentView.deferredCodeHighlightDelayForTesting = .milliseconds(180)
        defer { ToolTimelineRowContentView.deferredCodeHighlightDelayForTesting = nil }

        let text = (1...24)
            .map { index in
                "let line\(index) = \"" + String(repeating: "abcdefghij", count: 18) + "\""
            }
            .joined(separator: "\n")
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: text,
            language: .swift,
            startLine: 1,
            isStreaming: false
        )
        let configuration = makeOwnershipToolConfiguration(
            expandedContent: .code(text: text, language: .swift, startLine: 1, filePath: "Large.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: configuration)
        _ = fittedOwnershipSize(for: view, width: 360)

        view.expandedViewportMode = .none
        view.expandedCodeDeferredHighlightSignature = nil

        try await Task.sleep(for: .milliseconds(400))
        drainOwnershipMainQueue()

        #expect(ToolRowRenderCache.get(signature: signature) == nil)
        let rendered = (privateOwnershipView(named: "expandedLabel", in: view) as? UITextView)?
            .attributedText?.string ?? ""
        #expect(!rendered.contains("│"))
    }
}

@MainActor
@Suite("SyntaxHighlighter source preservation")
struct SyntaxHighlighterSourcePreservationTests {
    @Test func highlightPreservesSourceBeyondMaxLines() {
        let lineCount = SyntaxHighlighter.maxLines + 12
        let code = (1...lineCount).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightUsesCapturedThemeNotRuntimeTheme() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.light)
        let result = SyntaxHighlighter.highlight("let value = 1", language: .swift, themeID: .dark)
        #expect(foregroundColor(of: "let", in: result) == UIColor(ThemePalettes.dark.syntaxKeyword))
        #expect(foregroundColor(of: "let", in: result) != UIColor(ThemePalettes.light.syntaxKeyword))
    }

    @Test func remainderBeyondMaxLinesUsesNeutralBaseColor() {
        let lineCount = SyntaxHighlighter.maxLines + 40
        let lines = ["let first = 1"] + (2...lineCount).map { "plainTail\($0) = \($0)" }
        let code = lines.joined(separator: "\n")
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)

        let tail = result.string as NSString
        let tailLocation = tail.range(of: "plainTail\(lineCount)").location
        #expect(tailLocation != NSNotFound)
        let tailColor = result.attribute(
            .foregroundColor,
            at: tailLocation,
            effectiveRange: nil
        ) as? UIColor
        #expect(tailColor == UIColor(ThemeRuntimeState.currentThemeID().palette.syntaxVariable))
        #expect(tailColor != UIColor(ThemeRuntimeState.currentThemeID().palette.syntaxKeyword))
    }

    @Test func shareHighlightedCodeUsesDeclaredExportFont() {
        let attributed = FileShareService.debugHighlightedAttributedStringForTesting(
            "let value = 1",
            language: "swift",
            palette: ThemePalettes.dark
        )
        let font = attributed.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? UIFont
        #expect(font?.pointSize == FileShareService.debugCodePDFFontSizeForTesting)
        #expect(font?.familyName == UIFont.monospacedSystemFont(ofSize: 14, weight: .regular).familyName)
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }
}

// MARK: - Helpers

private func fence(_ language: String, _ code: String) -> String {
    "```\(language)\n\(code)\n```"
}

@MainActor
private func codeText(in root: UIView) -> String {
    codeAttributedText(in: root)?.string
        ?? timelineAllTextViews(in: root).first { $0.accessibilityIdentifier == "markdown.codeBlock.text" }?.text
        ?? timelineAllTextViews(in: root).first?.text
        ?? ""
}

@MainActor
private func codeAttributedText(in root: UIView) -> NSAttributedString? {
    if let labeled = timelineAllTextViews(in: root).first(where: {
        $0.accessibilityIdentifier == "markdown.codeBlock.text"
    }) {
        return labeled.attributedText
    }
    return timelineAllTextViews(in: root).first?.attributedText
}

@MainActor
private func makeFullScreenCodeBody(content: String, themeID: ThemeID) -> NativeFullScreenCodeBody {
    let body = NativeFullScreenCodeBody(
        content: content,
        language: "swift",
        startLine: 1,
        palette: themeID.palette,
        themeID: themeID,
        reviewCommentSelectionRouter: nil,
        reviewCommentSourceContext: nil
    )
    body.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
    body.setNeedsLayout()
    body.layoutIfNeeded()
    return body
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

private func foregroundColor(of substring: String, in attributed: NSAttributedString) -> UIColor? {
    let range = (attributed.string as NSString).range(of: substring)
    guard range.location != NSNotFound else { return nil }
    return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
}

@MainActor
private func waitUntil(
    timeout: Duration,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    if !condition() {
        Issue.record("Timed out waiting for highlight ownership condition")
    }
}

@MainActor
private func makeOwnershipToolConfiguration(
    expandedContent: ToolPresentationBuilder.ToolExpandedContent,
    isExpanded: Bool
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        itemID: "syntax-highlight-ownership-tool",
        title: "tool title",
        preview: nil,
        expandedContent: expandedContent,
        copyCommandText: "echo hi",
        copyOutputText: "hi",
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "read",
        toolNameColor: .systemBlue,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: isExpanded,
        isDone: true,
        isError: false,
        startedAt: nil,
        elapsedSeconds: nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}

@MainActor
private func privateOwnershipView(named name: String, in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIView
}

@MainActor
private func drainOwnershipMainQueue(passes: Int = 3) {
    for _ in 0..<max(1, passes) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func fittedOwnershipSize(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    container.layoutIfNeeded()
    view.layoutIfNeeded()
    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
