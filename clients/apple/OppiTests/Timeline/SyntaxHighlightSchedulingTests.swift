import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Syntax highlight admission then scheduling")
@MainActor
struct SyntaxHighlightSchedulingMatrixTests {
    struct Case: Sendable {
        let name: String
        let isStreaming: Bool
        let kind: StreamingRenderPolicy.ContentKind
        let byteCount: Int
        let lineCount: Int
        let maxLineByteCount: Int
        let pressure: StreamingRenderPolicy.ResourcePressure
        let consumer: StreamingRenderPolicy.WorkConsumer
        let expected: StreamingRenderPolicy.RenderTier
    }

    @Test("streaming, size, pressure, and consumer compose admission before scheduling")
    func matrix() {
        for testCase in Self.cases {
            let tier = StreamingRenderPolicy.tier(
                isStreaming: testCase.isStreaming,
                contentKind: testCase.kind,
                byteCount: testCase.byteCount,
                lineCount: testCase.lineCount,
                maxLineByteCount: testCase.maxLineByteCount,
                pressure: testCase.pressure,
                consumer: testCase.consumer
            )
            #expect(tier == testCase.expected, "\(testCase.name)")
        }
    }

    private static let smallBytes = 200
    private static let smallLines = 8
    private static let smallMaxLine = 20
    private static let largeBytes = 8 * 1024
    private static let largeLines = 120
    private static let longLine = 220

    static let cases: [Case] = [
        Case(
            name: "streaming code stays cheap",
            isStreaming: true,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .nominal,
            consumer: .visible,
            expected: .cheap
        ),
        Case(
            name: "streaming large code stays cheap",
            isStreaming: true,
            kind: .code(language: .known),
            byteCount: largeBytes,
            lineCount: largeLines,
            maxLineByteCount: longLine,
            pressure: .nominal,
            consumer: .explicit,
            expected: .cheap
        ),
        Case(
            name: "small known code is synchronous when admitted",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .nominal,
            consumer: .visible,
            expected: .full
        ),
        Case(
            name: "large known code defers when admitted",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: largeBytes,
            lineCount: largeLines,
            maxLineByteCount: smallMaxLine,
            pressure: .nominal,
            consumer: .explicit,
            expected: .deferred
        ),
        Case(
            name: "serious visible code is cheap",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .serious,
            consumer: .visible,
            expected: .cheap
        ),
        Case(
            name: "serious explicit code is cheap",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: largeBytes,
            lineCount: largeLines,
            maxLineByteCount: longLine,
            pressure: .serious,
            consumer: .explicit,
            expected: .cheap
        ),
        Case(
            name: "critical visible code is cheap",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .critical,
            consumer: .visible,
            expected: .cheap
        ),
        Case(
            name: "critical explicit code does not fall through to full",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .critical,
            consumer: .explicit,
            expected: .cheap
        ),
        Case(
            name: "critical explicit large code does not defer highlight work",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: largeBytes,
            lineCount: largeLines,
            maxLineByteCount: longLine,
            pressure: .critical,
            consumer: .explicit,
            expected: .cheap
        ),
        Case(
            name: "low power is at least serious for code",
            isStreaming: false,
            kind: .code(language: .known),
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: StreamingRenderPolicy.ResourcePressure(
                thermalState: .nominal,
                isLowPowerModeEnabled: true
            ),
            consumer: .explicit,
            expected: .cheap
        ),
        Case(
            name: "markdown stays cheap under serious",
            isStreaming: false,
            kind: .markdown,
            byteCount: smallBytes,
            lineCount: smallLines,
            maxLineByteCount: smallMaxLine,
            pressure: .serious,
            consumer: .visible,
            expected: .cheap
        ),
        Case(
            name: "bash output kind is not syntax admission",
            isStreaming: false,
            kind: .bash,
            byteCount: largeBytes,
            lineCount: largeLines,
            maxLineByteCount: smallMaxLine,
            pressure: .serious,
            consumer: .explicit,
            expected: .full
        ),
    ]
}

@Suite("Tool row code reuses cache before syntax scheduling")
@MainActor
struct SyntaxHighlightCodeSchedulingTests {
    @Test("refused admission does not start highlight or deferred work")
    func refusedAdmissionDoesNotStartSyntaxWork() {
        ToolRowRenderCache.evictAll()
        let text = "let answer = 42"
        let before = ToolRowCodeRenderStrategy.highlightWorkCountForTesting
        let result = render(text: text, language: .swift, resourcePressure: .critical)
        #expect(result.output.deferredHighlight == nil)
        #expect(result.label.text == text)
        #expect(result.label.attributedText?.string.contains("│") != true)
        #expect(ToolRowCodeRenderStrategy.highlightWorkCountForTesting == before)
    }

    @Test("valid cached paint is reused under pressure")
    func cacheHitIsPreservedUnderPressure() {
        ToolRowRenderCache.evictAll()
        let text = "let answer = 42"
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: text,
            language: .swift,
            startLine: 1,
            isStreaming: false
        )
        let cached = ToolRowTextRenderer.makeCodeAttributedText(
            text: text,
            language: .swift,
            startLine: 1
        )
        ToolRowRenderCache.set(signature: signature, attributed: cached)

        let before = ToolRowCodeRenderStrategy.highlightWorkCountForTesting
        let result = render(
            text: text,
            language: .swift,
            resourcePressure: .serious,
            isCurrentModeCode: true
        )
        #expect(result.output.deferredHighlight == nil)
        #expect(result.label.attributedText?.string == cached.string)
        #expect(result.label.attributedText?.string.contains("│") == true)
        #expect(ToolRowRenderCache.get(signature: signature) === cached)
        #expect(ToolRowCodeRenderStrategy.highlightWorkCountForTesting == before)
    }

    @Test("recovery without content change schedules highlight")
    func recoveryWithoutContentChangeHighlights() {
        ToolRowRenderCache.evictAll()
        let text = "let answer = 42"
        let suppressed = render(
            text: text,
            language: .swift,
            resourcePressure: .serious,
            isCurrentModeCode: true
        )
        #expect(suppressed.output.deferredHighlight == nil)
        #expect(suppressed.label.text == text)

        let recovered = render(
            text: text,
            language: .swift,
            resourcePressure: .nominal,
            label: suppressed.label,
            previousSignature: suppressed.output.renderSignature,
            previousRenderedText: suppressed.output.renderedText,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )
        #expect(recovered.output.deferredHighlight == nil)
        #expect(recovered.label.attributedText?.string.contains("│") == true)
        #expect(recovered.label.attributedText?.string.contains("let answer") == true)
    }

    private func render(
        text: String,
        language: SyntaxLanguage?,
        isStreaming: Bool = false,
        resourcePressure: StreamingRenderPolicy.ResourcePressure = .nominal,
        label: UITextView = UITextView(),
        previousSignature: Int? = nil,
        previousRenderedText: String? = nil,
        isCurrentModeCode: Bool = false,
        wasExpandedVisible: Bool = false
    ) -> (label: UITextView, output: ExpandedRenderOutput) {
        let output = ToolRowCodeRenderStrategy.render(
            text: text,
            language: language,
            startLine: 1,
            isStreaming: isStreaming,
            expandedLabel: label,
            expandedScrollView: UIScrollView(),
            previousSignature: previousSignature,
            previousRenderedText: previousRenderedText,
            previousAutoFollow: false,
            isCurrentModeCode: isCurrentModeCode,
            wasExpandedVisible: wasExpandedVisible,
            resourcePressure: resourcePressure
        )
        return (label, output)
    }
}

@Suite("Bash command syntax scheduling")
@MainActor
struct SyntaxHighlightBashCommandSchedulingTests {
    @Test("refused admission does not highlight a new command")
    func refusedAdmissionDoesNotHighlightCommand() {
        ToolRowRenderCache.evictAll()
        let view = BashToolRowView()
        let before = view.debugCommandHighlightWorkCountForTesting
        _ = view.apply(
            input: BashRenderInput(
                command: "echo 'hello' && ls -la",
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false,
                resourcePressure: .critical
            ),
            outputColor: .white,
            wasOutputVisible: false
        )
        let displayed = view.commandLabel.attributedText ?? NSAttributedString(string: view.commandLabel.text ?? "")
        #expect(uniqueForegroundColorCount(displayed) < 2)
        #expect(view.debugCommandHighlightWorkCountForTesting == before)
    }

    @Test("cached command colors survive pressure")
    func cacheHitPreservesCommandColors() throws {
        ToolRowRenderCache.evictAll()
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: "echo 'hello' && ls -la",
            output: nil,
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)
        let highlighted = try #require(view.commandLabel.attributedText)
        #expect(uniqueForegroundColorCount(highlighted) >= 2)
        let workAfterFirst = view.debugCommandHighlightWorkCountForTesting

        _ = view.apply(
            input: BashRenderInput(
                command: input.command,
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false,
                resourcePressure: .serious
            ),
            outputColor: .white,
            wasOutputVisible: false
        )
        let after = try #require(view.commandLabel.attributedText)
        #expect(uniqueForegroundColorCount(after) >= 2)
        #expect(view.debugCommandHighlightWorkCountForTesting == workAfterFirst)
    }

    @Test("recovery without content change highlights the command")
    func recoveryWithoutContentChangeHighlightsCommand() throws {
        ToolRowRenderCache.evictAll()
        let view = BashToolRowView()
        let command = "echo 'hello' && ls -la"
        _ = view.apply(
            input: BashRenderInput(
                command: command,
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false,
                resourcePressure: .serious
            ),
            outputColor: .white,
            wasOutputVisible: false
        )
        let suppressed = view.commandLabel.attributedText ?? NSAttributedString(string: view.commandLabel.text ?? "")
        #expect(uniqueForegroundColorCount(suppressed) < 2)

        _ = view.apply(
            input: BashRenderInput(
                command: command,
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false,
                resourcePressure: .nominal
            ),
            outputColor: .white,
            wasOutputVisible: false
        )
        let recovered = try #require(view.commandLabel.attributedText)
        #expect(uniqueForegroundColorCount(recovered) >= 2)
        #expect(recovered.string.contains("echo 'hello'"))
    }

    @Test("delayed command highlight does not publish a stale command")
    func delayedCommandHighlightDoesNotPublishStaleResult() async throws {
        ToolRowRenderCache.evictAll()
        BashToolRowView.deferredCommandHighlightDelayForTesting = .milliseconds(180)
        defer { BashToolRowView.deferredCommandHighlightDelayForTesting = nil }

        let view = BashToolRowView()
        let commandA = largeShellCommand("alphaUnique")
        let commandB = largeShellCommand("betaUnique")
        #expect(commandA.utf8.count > StreamingRenderPolicy.deferredHighlightByteThreshold)

        _ = view.apply(
            input: BashRenderInput(
                command: commandA,
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false
            ),
            outputColor: .white,
            wasOutputVisible: false
        )
        _ = view.apply(
            input: BashRenderInput(
                command: commandB,
                output: nil,
                unwrapped: false,
                isError: false,
                isStreaming: false
            ),
            outputColor: .white,
            wasOutputVisible: false
        )

        try await waitUntil(timeout: .seconds(2)) {
            let displayed = view.commandLabel.attributedText?.string ?? view.commandLabel.text ?? ""
            return displayed.contains("betaUnique")
                && uniqueForegroundColorCount(view.commandLabel.attributedText ?? NSAttributedString()) >= 2
        }

        let displayed = view.commandLabel.attributedText?.string ?? view.commandLabel.text ?? ""
        #expect(displayed.contains("betaUnique"))
        #expect(!displayed.contains("alphaUnique"))
        let attributed = try #require(view.commandLabel.attributedText)
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }
}

@Suite("Markdown syntax admission preserves cache and export")
@MainActor
struct SyntaxHighlightMarkdownSchedulingTests {
    @Test("already highlighted fences keep colors under pressure")
    func alreadyHighlightedFenceSurvivesPressure() async throws {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let source = """
        ```swift
        let answer = 42
        ```
        """
        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .nominal
        ))
        markdown.layoutIfNeeded()
        let code = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
        try await waitUntil(timeout: .seconds(2)) {
            code.debugHasHighlightedTextForTesting
        }
        let workAfterFirst = markdown.debugHighlightWorkCountForTesting
        #expect(workAfterFirst >= 1)

        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .serious
        ))
        markdown.layoutIfNeeded()
        #expect(code.debugHasHighlightedTextForTesting)
        #expect(markdown.debugHighlightWorkCountForTesting == workAfterFirst)
        let attributed = try #require(codeAttributedText(in: code))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }

    @Test("recovery without content change highlights a previously suppressed fence")
    func recoveryWithoutContentChangeHighlightsFence() async throws {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let source = """
        ```swift
        let answer = 42
        ```
        """
        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .serious
        ))
        markdown.layoutIfNeeded()
        let code = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
        #expect(code.debugHasHighlightedTextForTesting == false)

        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .nominal
        ))
        markdown.layoutIfNeeded()
        try await waitUntil(timeout: .seconds(2)) {
            code.debugHasHighlightedTextForTesting
        }
        let attributed = try #require(codeAttributedText(in: code))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }

    @Test("export still highlights under critical pressure")
    func exportRemainsDeterministicUnderPressure() throws {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        markdown.apply(configuration: .make(
            content: """
            ```swift
            let answer = 42
            ```
            """,
            isStreaming: false,
            themeID: .dark,
            renderingMode: .export,
            resourcePressure: .critical
        ))
        markdown.layoutIfNeeded()
        let code = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown))
        #expect(code.debugHasHighlightedTextForTesting)
        let attributed = try #require(codeAttributedText(in: code))
        #expect(uniqueForegroundColorCount(attributed) >= 2)
    }
}

private func largeShellCommand(_ token: String) -> String {
    (1...24)
        .map { index in
            "echo \(token)_\(index) " + String(repeating: "abcdefghij", count: 18)
        }
        .joined(separator: "\n")
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
        Issue.record("Timed out waiting for syntax scheduling condition")
    }
}
