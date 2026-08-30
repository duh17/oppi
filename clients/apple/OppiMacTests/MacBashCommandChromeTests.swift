import Testing
@testable import Oppi

@Suite("Mac bash command chrome")
struct MacBashCommandChromeTests {
    @Test func prefersCommandPromptFromOutputOverArgsSummary() {
        let command = MacBashCommandChrome.commandText(
            tool: "bash",
            argsSummary: "command: echo args",
            outputText: "$ npm test\nPASS server/tests/session-routes.test.ts"
        )

        #expect(command == "npm test")
    }

    @Test func fallsBackToArgsSummaryWhenOutputHasNoPrompt() {
        let command = MacBashCommandChrome.commandText(
            tool: "functions.bash",
            argsSummary: "command: ls -la",
            outputText: "total 8\ndrwxr-xr-x  5 chenda  staff  160 ."
        )

        #expect(command == "ls -la")
    }

    @Test func usesRawArgsSummaryWhenCommandKeyIsMissing() {
        let command = MacBashCommandChrome.commandText(
            tool: "Bash",
            argsSummary: "git status --short",
            outputText: " M clients/apple/OppiMac/Views/MacSessionTimelineViews.swift"
        )

        #expect(command == "git status --short")
    }

    @Test func returnsNilForNonBashTools() {
        let command = MacBashCommandChrome.commandText(
            tool: "read",
            argsSummary: "path: README.md",
            outputText: "$ cat README.md\n# Oppi"
        )

        #expect(command == nil)
    }
}
