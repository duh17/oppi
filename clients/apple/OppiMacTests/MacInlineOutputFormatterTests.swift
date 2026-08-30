import Testing
@testable import Oppi

@Suite("Mac terminal and code output models")
struct MacInlineOutputFormatterTests {
    @Test func terminalOutputModelStripsANSISplitsCommandAndDetectsErrors() {
        let output = "\u{001B}[32m$ npm test\u{001B}[0m\n\u{001B}[31merror: test failed\u{001B}[0m\nexit code 1"
        let model = MacTerminalOutputModel(text: output)

        #expect(model.commandText == "npm test")
        #expect(model.outputText == "error: test failed\nexit code 1")
        #expect(model.isError)
        #expect(model.statusTitle == "Error output")
    }

    @Test func terminalOutputUsesSharedANSIStringControlStripping() {
        let output = "before\u{001B}]8;;https://example.com\u{0007}link\u{001B}]8;;\u{0007}after"

        #expect(MacTerminalOutputModel.strippingANSI(from: output) == "beforelinkafter")
    }

    @Test func codeOutputModelKeepsExplicitLanguageAndSourceText() {
        let code = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View { Text("Hello") }
        }
        """
        let model = MacCodeOutputModel(language: "swift", text: code)

        #expect(model.language == "swift")
        #expect(model.syntaxLanguage == .swift)
        #expect(model.text.contains("import SwiftUI"))
        #expect(model.text.components(separatedBy: .newlines).count == 5)
    }

    @Test func codeOutputModelDoesNotGuessLanguageFromSourceText() {
        let code = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View { Text("Hello") }
        }
        """
        let model = MacCodeOutputModel(language: nil, text: code)

        #expect(model.language == nil)
        #expect(model.syntaxLanguage == nil)
        #expect(model.text.contains("struct ExampleView"))
        #expect(model.text.components(separatedBy: .newlines).count == 5)
    }
}
