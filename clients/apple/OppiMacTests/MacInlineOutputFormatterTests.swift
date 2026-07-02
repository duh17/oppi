import Testing
@testable import Oppi

@Suite("Mac inline output formatter")
struct MacInlineOutputFormatterTests {
    @Test func parsesHeadingsBulletsAndParagraphs() {
        let blocks = MacInlineOutputFormatter.blocks(from: """
        # Summary
        Built the shell.
        Still needs polish.

        - Sidebar
        - Timeline
        """)

        #expect(blocks == [
            .heading(level: 1, text: "Summary"),
            .paragraph("Built the shell. Still needs polish."),
            .bullet("Sidebar"),
            .bullet("Timeline"),
        ])
    }

    @Test func preservesFencedCodeBlocks() {
        let blocks = MacInlineOutputFormatter.blocks(from: """
        Here is output:
        ```swift
        let answer = 42
        print(answer)
        ```
        Done.
        """)

        #expect(blocks == [
            .paragraph("Here is output:"),
            .code(language: "swift", text: "let answer = 42\nprint(answer)"),
            .paragraph("Done."),
        ])
    }

    @Test func detectsTerminalLikeOutput() {
        let output = """
        $ npm test
        SwiftCompile normal arm64 File.swift
        Ld Oppi.app
        """

        #expect(MacInlineOutputFormatter.shouldUseTerminalBlock(for: output))
    }

    @Test func terminalOutputModelStripsANSISplitsCommandAndDetectsErrors() {
        let output = "\u{001B}[32m$ npm test\u{001B}[0m\n\u{001B}[31merror: test failed\u{001B}[0m\nexit code 1"
        let model = MacTerminalOutputModel(text: output)

        #expect(model.commandText == "npm test")
        #expect(model.outputText == "error: test failed\nexit code 1")
        #expect(model.isError)
        #expect(model.statusTitle == "Error output")
    }

    @Test func detectsANSIPrefixedTerminalOutput() {
        let output = "\u{001B}[32m$ npm test\u{001B}[0m\nPASS server/tests/session-routes.test.ts"

        #expect(MacInlineOutputFormatter.shouldUseTerminalBlock(for: output))
    }

    @Test func diffOutputModelClassifiesUnifiedDiffLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 111..222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,3 @@
         struct Example {}
        -let old = true
        +let new = true
        """
        let model = MacDiffOutputModel(text: diff)

        #expect(MacDiffOutputModel.shouldRender(text: diff))
        #expect(model.lines.map(\.kind) == [
            .fileHeader,
            .fileHeader,
            .fileHeader,
            .fileHeader,
            .hunk,
            .context,
            .removal,
            .addition,
        ])
        #expect(model.changeSummary == "1 addition, 1 removal")
    }

    @Test func codeOutputModelAddsLineNumbersAndInfersLanguage() {
        let code = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View { Text("Hello") }
        }
        """
        let model = MacCodeOutputModel(language: nil, text: code)

        #expect(MacCodeOutputModel.shouldRenderStandalone(text: code))
        #expect(model.language == "swift")
        #expect(model.syntaxLanguage == .swift)
        #expect(model.lines.first?.number == 1)
        #expect(model.lines.last?.number == 5)
    }

    @Test func mediaOutputModelExtractsInlineDataURIs() throws {
        let pngDataURI = "data:image/png;base64,iVBORw0KGgo="
        let audioDataURI = "data:audio/wav;base64,UklGRg=="
        let output = "Preview image: ![plot](\(pngDataURI))\nVoice note: \(audioDataURI)"
        let model = MacMediaOutputModel(text: output)

        #expect(MacMediaOutputModel.shouldRender(text: output))
        #expect(model.items.count == 2)
        #expect(model.items.map(\.kind) == [.image, .audio])
        #expect(model.items.first?.mimeType == "image/png")
        #expect(model.items.first?.label == "plot")
        #expect(model.items.first?.byteCount == 8)
        #expect(model.items.last?.byteCount == 4)
    }
}
