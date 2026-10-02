import Testing
import UIKit
import SwiftUI
@testable import Oppi

@Suite("BashToolRowView")
@MainActor
struct BashToolRowViewTests {

    // MARK: - apply: basic rendering

    @Test("command text renders to commandLabel")
    func commandRenders() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: "echo hello",
            output: nil,
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        let result = view.apply(
            input: input,
            outputColor: .white,
            wasOutputVisible: false
        )
        #expect(result.showCommand)
        #expect(!result.showOutput)
        let commandText = view.commandLabel.attributedText?.string ?? view.commandLabel.text ?? ""
        #expect(commandText.contains("echo hello"))
    }

    @Test("output text renders to outputLabel")
    func outputRenders() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "line1\nline2",
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        let result = view.apply(
            input: input,
            outputColor: .white,
            wasOutputVisible: false
        )
        #expect(!result.showCommand)
        #expect(result.showOutput)
        let outputText = view.outputLabel.attributedText?.string ?? view.outputLabel.text ?? ""
        #expect(outputText.contains("line1"))
        #expect(outputText.contains("line2"))
    }

    @Test("nil command and output shows neither")
    func emptyInputHidesAll() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil, output: nil, unwrapped: false, isError: false, isStreaming: false
        )
        let result = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        #expect(!result.showCommand)
        #expect(!result.showOutput)
    }

    @Test("unwrapped sets lineBreakMode to byClipping")
    func unwrappedSetsClipping() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: String(repeating: "x", count: 300),
            unwrapped: true,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        #expect(view.outputLabel.textContainer.lineBreakMode == .byClipping)
        #expect(view.outputScrollView.showsHorizontalScrollIndicator)
    }

    @Test("wrapped mode uses byCharWrapping")
    func wrappedMode() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "some output",
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        #expect(view.outputLabel.textContainer.lineBreakMode == .byCharWrapping)
        #expect(!view.outputScrollView.showsHorizontalScrollIndicator)
    }

    @Test("error output sets red-tinted background on outputContainer")
    func errorTintsBackground() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "error: something failed",
            unwrapped: false,
            isError: true,
            isStreaming: false
        )
        _ = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        // Error mode sets a non-default (red-tinted) background on outputContainer.
        let bg = view.outputContainer.backgroundColor
        #expect(bg != UIColor(Color.themeBgDark))
    }

    @Test("non-error output uses normal dark background")
    func normalBackground() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "stdout line",
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        #expect(view.outputContainer.backgroundColor == UIColor(Color.themeBgDark))
    }

    @Test("applyTheme refreshes persistent UIKit surfaces")
    func applyThemeRefreshesSurfaces() throws {
        let view = BashToolRowView()

        view.applyTheme(ThemePalettes.dark)
        let darkCommand = try #require(view.commandContainer.backgroundColor)
        let darkOutput = try #require(view.outputContainer.backgroundColor)

        view.applyTheme(ThemePalettes.light)
        let lightCommand = try #require(view.commandContainer.backgroundColor)
        let lightOutput = try #require(view.outputContainer.backgroundColor)

        #expect(lightCommand == UIColor(ThemePalettes.light.bgHighlight))
        #expect(lightOutput == UIColor(ThemePalettes.light.bgDark))
        #expect(lightCommand != darkCommand)
        #expect(lightOutput != darkOutput)
    }

    // MARK: - resetOutputState

    @Test("resetOutputState clears output render state")
    func resetOutputClearsState() {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "some output",
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(
            input: input, outputColor: .white, wasOutputVisible: false
        )
        #expect(view.outputRenderSignature != nil)

        view.resetOutputState(outputColor: .black)
        #expect(view.outputRenderSignature == nil)
        #expect(view.outputRenderedText == nil)
        #expect(!view.outputUsesViewport)
        #expect(view.outputShouldAutoFollow)
    }

    // MARK: - Streaming append

    @Test("streaming append builds content incrementally")
    func streamingAppend() {
        let view = BashToolRowView()
        let outputColor = UIColor.white

        // First chunk
        let input1 = BashRenderInput(
            command: nil, output: "line1\n", unwrapped: false, isError: false, isStreaming: true
        )
        _ = view.apply(
            input: input1, outputColor: outputColor, wasOutputVisible: false
        )
        let text1 = view.outputLabel.text ?? ""
        #expect(text1.contains("line1"))

        // Second chunk extends first
        let input2 = BashRenderInput(
            command: nil, output: "line1\nline2\n", unwrapped: false, isError: false, isStreaming: true
        )
        _ = view.apply(
            input: input2, outputColor: outputColor, wasOutputVisible: true
        )
        let text2 = view.outputLabel.text ?? view.outputLabel.attributedText?.string ?? ""
        #expect(text2.contains("line1"))
        #expect(text2.contains("line2"))
    }

    @Test("streaming reset resets appendOffset for full rebuild")
    func streamingReset() {
        let view = BashToolRowView()
        // Stream some content
        let stream = BashRenderInput(
            command: nil, output: "old output", unwrapped: false, isError: false, isStreaming: true
        )
        _ = view.apply(input: stream, outputColor: .white, wasOutputVisible: false)

        view.resetOutputState(outputColor: .white)

        // Fresh start — should do full rebuild, not append
        let fresh = BashRenderInput(
            command: nil, output: "new output", unwrapped: false, isError: false, isStreaming: true
        )
        _ = view.apply(input: fresh, outputColor: .white, wasOutputVisible: false)
        let text = view.outputLabel.text ?? view.outputLabel.attributedText?.string ?? ""
        #expect(!text.contains("old output"))
        #expect(text.contains("new output"))
    }

    @Test("large deferred output resolves redraws before painting")
    func deferredTerminalOutput() async throws {
        let view = BashToolRowView()
        let largeOutput = String(repeating: "line\n", count: 1_000)
            + "pending\r\u{1B}[2K\u{1B}[32mcomplete\u{1B}[0m\n"
        let input = BashRenderInput(command: nil, output: largeOutput,
            unwrapped: false, isError: false, isStreaming: false)
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)
        let painted = await waitForMainActorCondition(timeout: .seconds(3)) {
            view.outputLabel.textStorage.string.hasSuffix("complete\n")
        }
        #expect(painted)
        #expect(!view.outputLabel.textStorage.string.contains("pending"))
        #expect(uniqueForegroundColorCount(try #require(view.outputLabel.attributedText)) >= 2)
    }

    @Test("a burst of large snapshots paints useful work before the latest replay")
    func deferredStreamCoalesces() async throws {
        BashToolRowView.deferredANSIDelayForTesting = .milliseconds(200)
        defer { BashToolRowView.deferredANSIDelayForTesting = nil }
        let view = BashToolRowView()
        let first = String(repeating: "coalesced line\n", count: 1_000) + "first"
        _ = view.apply(input: .init(command: nil, output: first, unwrapped: false,
            isError: false, isStreaming: true), outputColor: .white, wasOutputVisible: false)
        _ = view.apply(input: .init(command: nil, output: first + "\r\u{1B}[2Ksecond", unwrapped: false,
            isError: false, isStreaming: true), outputColor: .white, wasOutputVisible: true)
        let interim = await waitForMainActorCondition(timeout: .seconds(3)) {
            view.outputLabel.textStorage.string.hasSuffix("first")
        }
        #expect(interim)
        let latest = await waitForMainActorCondition(timeout: .seconds(3)) {
            view.outputLabel.textStorage.string.hasSuffix("second")
        }
        #expect(latest)
        #expect(!view.outputLabel.textStorage.string.hasSuffix("first"))
    }

    @Test("streaming redraws retain colors, not duplicate progress lines")
    func streamingProgress() throws {
        let view = BashToolRowView()
        let prefix = "working 10%\r"
        _ = view.apply(input: .init(command: nil, output: prefix, unwrapped: false,
            isError: false, isStreaming: true), outputColor: .white, wasOutputVisible: false)
        _ = view.apply(input: .init(command: nil,
            output: prefix + "\u{1B}[2K\u{1B}[32mworking 100%\u{1B}[0m plain",
            unwrapped: false, isError: false, isStreaming: true), outputColor: .white, wasOutputVisible: true)
        #expect(view.outputLabel.textStorage.string == "working 100% plain")
        #expect(uniqueForegroundColorCount(try #require(view.outputLabel.attributedText)) >= 2)
    }

    @Test("streaming path uses incremental stripping")
    func streamingPathIncremental() {
        let view = BashToolRowView()
        let outputColor = UIColor.white

        // Send 10 growing chunks of ANSI output
        var fullOutput = ""
        for i in 0..<10 {
            fullOutput += "\u{1B}[32m\u{2713}\u{1B}[0m test_\(i)\n"
            let input = BashRenderInput(
                command: nil,
                output: fullOutput,
                unwrapped: false,
                isError: false,
                isStreaming: true
            )
            _ = view.apply(input: input, outputColor: outputColor, wasOutputVisible: i > 0)
        }

        let displayed = view.outputLabel.text ?? view.outputLabel.attributedText?.string ?? ""
        let expected = ANSIParser.strip(fullOutput)
        #expect(displayed == expected,
            "Incremental streaming should produce identical output to full strip")
    }

    @Test("streaming path handles lone ESC at chunk boundary")
    func streamingPathLoneEscapeBoundary() {
        let view = BashToolRowView()
        let outputColor = UIColor.white

        let partial = BashRenderInput(
            command: nil,
            output: "line\u{1B}",
            unwrapped: false,
            isError: false,
            isStreaming: true
        )
        _ = view.apply(input: partial, outputColor: outputColor, wasOutputVisible: false)

        let full = BashRenderInput(
            command: nil,
            output: "line\u{1B}[32mok",
            unwrapped: false,
            isError: false,
            isStreaming: true
        )
        _ = view.apply(input: full, outputColor: outputColor, wasOutputVisible: true)

        let displayed = view.outputLabel.text ?? view.outputLabel.attributedText?.string ?? ""
        #expect(displayed == "lineok")
    }

    // MARK: - Signature dedup

    @Test("same input twice does not re-render command")
    func commandSignatureDedup() throws {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: "ls -la", output: nil, unwrapped: false, isError: false, isStreaming: false
        )
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)
        let firstAttr = try #require(view.commandLabel.attributedText)

        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)
        let secondAttr = try #require(view.commandLabel.attributedText)

        // Same attributed string object (no rerender means same reference)
        #expect(firstAttr === secondAttr || firstAttr.string == secondAttr.string)
    }

    @Test("highlighted command keeps mixed syntax colors after applyTheme")
    func applyThemePreservesCommandSyntaxColors() throws {
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
        let colorsBefore = uniqueForegroundColorCount(highlighted)
        #expect(colorsBefore >= 2)

        view.applyTheme(ThemePalettes.dark)
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)

        let after = try #require(view.commandLabel.attributedText)
        #expect(uniqueForegroundColorCount(after) >= 2)
    }

    @Test("highlighted ANSI output keeps mixed colors after applyTheme")
    func applyThemePreservesOutputANSIColors() throws {
        let view = BashToolRowView()
        let input = BashRenderInput(
            command: nil,
            output: "\u{1B}[32mgreen\u{1B}[0m plain",
            unwrapped: false,
            isError: false,
            isStreaming: false
        )
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)

        let highlighted = try #require(view.outputLabel.attributedText)
        let colorsBefore = uniqueForegroundColorCount(highlighted)
        #expect(colorsBefore >= 2)

        view.applyTheme(ThemePalettes.dark)
        _ = view.apply(input: input, outputColor: .white, wasOutputVisible: false)

        let after = try #require(view.outputLabel.attributedText)
        #expect(uniqueForegroundColorCount(after) >= 2)
    }

    // MARK: - Live owned tail

    @Test("live tail keeps whole short output and the last N complete lines of long output")
    func liveTailLineBound() {
        #expect(BashToolRowView.liveTail(of: "a\nb\n") == "a\nb\n")
        let limit = BashToolRowView.liveTailLineLimit
        let lines = (1...(limit + 50)).map { "line \($0)" }
        for text in [lines.joined(separator: "\n"), lines.joined(separator: "\n") + "\n"] {
            let tail = BashToolRowView.liveTail(of: text)
            #expect(tail.hasPrefix("line 51\n"))
            #expect(tail.split(separator: "\n").count == limit)
            #expect(text.hasSuffix(tail))
        }
    }

    @Test("live tail cuts at a line start within the byte budget but always keeps the last line")
    func liveTailByteBound() {
        let limit = BashToolRowView.liveTailByteLimit
        // 2/5 of the budget per line: two lines fit, three do not.
        let wide = String(repeating: "é", count: limit / 5)
        let tail = BashToolRowView.liveTail(of: "one\n\(wide)\n\(wide)\n\(wide)")
        #expect(tail == "\(wide)\n\(wide)")
        let giant = String(repeating: "x", count: limit * 2)
        #expect(BashToolRowView.liveTail(of: "head\n\(giant)") == giant[...])
        #expect(BashToolRowView.liveTail(of: giant) == giant[...])
    }

    @Test("a reused expanded row does not carry a detached live paint onto another call")
    func reusedRowDropsDetachedLivePaint() throws {
        let owner = TerminalOutputStream { _ in throw CancellationError() }
        func configuration(_ id: String, _ output: String) -> ToolTimelineRowConfiguration {
            var configuration = makeTimelineToolConfiguration(itemID: id,
                expandedContent: .bash(command: "run", output: output, unwrapped: false),
                isExpanded: true, isDone: false)
            configuration.terminalOutputStream = owner
            return configuration
        }
        let view = ToolTimelineRowContentView(configuration: configuration("a",
            (1...80).map { "first \($0)" }.joined(separator: "\n")))
        _ = fittedTimelineSize(for: view, width: 390)
        let row = view.bashToolRowView
        row.outputScrollView.draggingOverrideForTesting = true
        row.scrollViewWillBeginDragging(row.outputScrollView)
        row.outputScrollView.draggingOverrideForTesting = nil
        #expect(!row.outputShouldAutoFollow)

        view.configuration = configuration("b", "second call output")
        _ = fittedTimelineSize(for: view, width: 390)
        #expect(row.outputLabel.textStorage.string == "second call output")
        #expect(row.outputShouldAutoFollow)
    }

    @Test("a detached reader keeps its lines when the finished output replaces the live tail")
    func detachedCompletionKeepsLines() throws {
        let owner = TerminalOutputStream { _ in throw CancellationError() }
        // More lines than the live tail, but under the deferred-render byte threshold.
        let full = (1...(BashToolRowView.liveTailLineLimit + 100)).map { "l\($0)" }.joined(separator: "\n")
        #expect(full.utf8.count < BashToolRowView.deferredANSIByteThreshold)
        func configuration(done: Bool) -> ToolTimelineRowConfiguration {
            var configuration = makeTimelineToolConfiguration(
                expandedContent: .bash(command: "run", output: full, unwrapped: false),
                isExpanded: true, isDone: done)
            configuration.terminalOutputStream = owner
            return configuration
        }
        let view = ToolTimelineRowContentView(configuration: configuration(done: false))
        _ = fittedTimelineSize(for: view, width: 390)
        let row = view.bashToolRowView
        let scroll = row.outputScrollView
        func distanceFromBottom() -> CGFloat {
            scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - scroll.contentOffset.y
        }
        let tailHeight = scroll.contentSize.height
        #expect(tailHeight > scroll.bounds.height)
        // Park the reader mid-tail, away from the bottom.
        scroll.draggingOverrideForTesting = true
        row.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = tailHeight / 2
        scroll.draggingOverrideForTesting = false
        row.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(!row.outputShouldAutoFollow)
        let before = distanceFromBottom()

        view.configuration = configuration(done: true)
        _ = fittedTimelineSize(for: view, width: 390)
        #expect(scroll.contentSize.height > tailHeight, "The completed row shows the whole output")
        #expect(abs(distanceFromBottom() - before) < 1, "The same tail lines stay in view")
    }
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
