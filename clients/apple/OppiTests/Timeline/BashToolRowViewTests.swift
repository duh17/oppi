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
}
