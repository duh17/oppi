import Testing
@testable import Oppi

// MARK: - Test Helpers

/// Extract tokens of a specific kind from scan results.
private func tokens(
    _ kind: SyntaxHighlighter.TokenKind,
    in code: String
) -> [(text: String, kind: SyntaxHighlighter.TokenKind)] {
    let ranges = TreeSitterHighlighter.scanTokenRanges(code, language: .shell) ?? []
    let utf16 = Array(code.utf16)
    return ranges.compactMap { range in
        let start = range.location
        let end = start + range.length
        guard start >= 0, end <= utf16.count else { return nil }
        guard range.kind == kind else { return nil }
        let slice = Array(utf16[start..<end])
        let text = String(utf16CodeUnits: slice, count: slice.count)
        return (text, range.kind)
    }
}

/// Extract all tokens from scan results as (text, kind) pairs.
private func allTokens(
    in code: String
) -> [(text: String, kind: SyntaxHighlighter.TokenKind)] {
    let ranges = TreeSitterHighlighter.scanTokenRanges(code, language: .shell) ?? []
    let utf16 = Array(code.utf16)
    return ranges.compactMap { range in
        let start = range.location
        let end = start + range.length
        guard start >= 0, end <= utf16.count else { return nil }
        let slice = Array(utf16[start..<end])
        let text = String(utf16CodeUnits: slice, count: slice.count)
        return (text, range.kind)
    }
}

/// Check that a specific substring is highlighted as the expected kind.
/// Uses the LAST matching token at that position (last-write-wins).
private func expectToken(
    _ substring: String,
    is expectedKind: SyntaxHighlighter.TokenKind,
    in code: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let ranges = TreeSitterHighlighter.scanTokenRanges(code, language: .shell) ?? []
    let utf16 = Array(code.utf16)
    let targetUTF16 = Array(substring.utf16)

    // Find the substring in the source
    guard let substringRange = findUTF16Range(targetUTF16, in: utf16) else {
        Issue.record(
            "Substring '\(substring)' not found in code",
            sourceLocation: sourceLocation
        )
        return
    }

    // Find all tokens that cover this range. Last one wins (last-write-wins).
    let covering = ranges.filter { range in
        let tokenStart = range.location
        let tokenEnd = tokenStart + range.length
        return tokenStart <= substringRange.lowerBound && tokenEnd >= substringRange.upperBound
    }

    guard let winner = covering.last else {
        Issue.record(
            "No token covers '\(substring)' — expected \(expectedKind)",
            sourceLocation: sourceLocation
        )
        return
    }

    #expect(
        winner.kind == expectedKind,
        "Expected '\(substring)' to be \(expectedKind), got \(winner.kind)",
        sourceLocation: sourceLocation
    )
}

/// Check that a substring is NOT highlighted (no token covers it,
/// or the covering token is .variable which is the default/unstyled kind).
private func expectDefault(
    _ substring: String,
    in code: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let ranges = TreeSitterHighlighter.scanTokenRanges(code, language: .shell) ?? []
    let utf16 = Array(code.utf16)
    let targetUTF16 = Array(substring.utf16)

    guard let substringRange = findUTF16Range(targetUTF16, in: utf16) else {
        Issue.record(
            "Substring '\(substring)' not found in code",
            sourceLocation: sourceLocation
        )
        return
    }

    // Check that no non-default token fully covers this range
    let covering = ranges.filter { range in
        let tokenStart = range.location
        let tokenEnd = tokenStart + range.length
        return tokenStart <= substringRange.lowerBound && tokenEnd >= substringRange.upperBound
    }

    let nonDefault = covering.filter { $0.kind != .variable }
    if let last = nonDefault.last {
        Issue.record(
            "Expected '\(substring)' to be default/unstyled, but got \(last.kind)",
            sourceLocation: sourceLocation
        )
    }
}

private func findUTF16Range(_ needle: [UInt16], in haystack: [UInt16]) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    outer: for i in 0...(haystack.count - needle.count) {
        for j in 0..<needle.count {
            if haystack[i + j] != needle[j] { continue outer }
        }
        return i..<(i + needle.count)
    }
    return nil
}

// MARK: - Basic Command Tests

@Suite("TreeSitter Bash — Commands")
struct TreeSitterBashCommandTests {

    @Test func simpleCommand() {
        let code = "whoami"
        expectToken("whoami", is: .function, in: code)
    }

    @Test func commandWithArguments() {
        let code = "cat file1.txt"
        expectToken("cat", is: .function, in: code)
    }

    @Test func commandWithPath() {
        let code = "cd /Users/testuser/workspace/oppi"
        expectToken("cd", is: .function, in: code)
    }

    @Test func pipeline() {
        let code = "cat foo | grep -v bar"
        expectToken("cat", is: .function, in: code)
        expectToken("|", is: .operator, in: code)
        expectToken("grep", is: .function, in: code)
    }

    @Test func compoundAnd() {
        let code = "cd /tmp && git commit -m \"hello\""
        expectToken("cd", is: .function, in: code)
        expectToken("&&", is: .operator, in: code)
        expectToken("git", is: .function, in: code)
    }

    @Test func compoundOr() {
        let code = "make || echo \"build failed\""
        expectToken("make", is: .function, in: code)
        expectToken("||", is: .operator, in: code)
        expectToken("echo", is: .function, in: code)
    }

    @Test func semicolonSeparated() {
        let code = "echo hello; echo world"
        let fns = tokens(.function, in: code)
        #expect(fns.count >= 2)
    }
}

// MARK: - String Tests (the core fix)

@Suite("TreeSitter Bash — Strings")
struct TreeSitterBashStringTests {

    @Test func doubleQuotedString() {
        let code = "echo \"hello world\""
        expectToken("echo", is: .function, in: code)
        expectToken("\"hello world\"", is: .string, in: code)
    }

    @Test func singleQuotedString() {
        let code = "echo 'no $expansion here'"
        expectToken("echo", is: .function, in: code)
        expectToken("'no $expansion here'", is: .string, in: code)
    }

    @Test func multiLineString() {
        // THE key test case from the screenshot bug.
        // Our old scanner colored each line independently, causing
        // "random blue" on continuation lines. Tree-sitter correctly
        // treats the entire quoted region as a single string.
        let code = """
        git commit -m "feat: show blue Question pill
        when agent asks a question
        Add AskRequestStore to track pending asks"
        """
        expectToken("git", is: .function, in: code)

        // The entire multi-line string should be .string
        let strings = tokens(.string, in: code)
        let fullString = strings.first {
            $0.text.contains("feat: show blue")
        }
        #expect(fullString != nil, "Multi-line string should be detected as .string")

        // Continuation lines should NOT be highlighted as commands
        let functions = tokens(.function, in: code)
        let badFunctions = functions.filter {
            $0.text == "when" || $0.text == "Add"
        }
        #expect(badFunctions.isEmpty, "Continuation lines inside string must not be commands")
    }

    @Test func multiLineStringWithVariables() {
        let code = """
        echo "hello $USER
        welcome to $HOME"
        """
        expectToken("echo", is: .function, in: code)
        // Variables inside strings should still be highlighted
        let types = tokens(.type, in: code)
        let userVar = types.first { $0.text == "USER" }
        #expect(userVar != nil, "Variable inside multi-line string should be detected")
    }

    @Test func emptyString() {
        let code = "echo \"\""
        expectToken("echo", is: .function, in: code)
        expectToken("\"\"", is: .string, in: code)
    }

    @Test func stringWithEscapes() {
        let code = #"echo "hello \"world\"""#
        expectToken("echo", is: .function, in: code)
    }

    @Test func ansiCString() {
        let code = "echo $'hello\\nworld'"
        expectToken("echo", is: .function, in: code)
    }
}

// MARK: - Variable Tests

@Suite("TreeSitter Bash — Variables")
struct TreeSitterBashVariableTests {

    @Test func simpleExpansion() {
        let code = "echo $HOME"
        expectToken("echo", is: .function, in: code)
        expectToken("HOME", is: .type, in: code)
    }

    @Test func bracedExpansion() {
        let code = "echo ${BASH_SOURCE[0]}"
        expectToken("echo", is: .function, in: code)
        expectToken("BASH_SOURCE", is: .type, in: code)
    }

    @Test func specialVariables() {
        let code = "echo $# $@ $?"
        expectToken("echo", is: .function, in: code)
    }

    @Test func variableAssignment() {
        let code = "FOO=bar xcodebuild -scheme Oppi"
        expectToken("FOO", is: .type, in: code)
        expectToken("xcodebuild", is: .function, in: code)
    }

    @Test func multipleAssignments() {
        let code = "VAR1=a VAR2=\"ok\" git diff"
        expectToken("VAR1", is: .type, in: code)
        expectToken("VAR2", is: .type, in: code)
        expectToken("git", is: .function, in: code)
    }

    @Test func exportAssignment() {
        let code = "export PATH=/usr/bin:$PATH"
        expectToken("export", is: .keyword, in: code)
        expectToken("PATH", is: .type, in: code)
    }
}

// MARK: - Keyword Tests

@Suite("TreeSitter Bash — Keywords")
struct TreeSitterBashKeywordTests {

    @Test func ifStatement() {
        // Use a variable name that doesn't contain "fi" to avoid substring ambiguity
        let code = "if [ -d path ]; then echo yes; fi"
        expectToken("if", is: .keyword, in: code)
        expectToken("then", is: .keyword, in: code)
        expectToken("echo", is: .function, in: code)
        expectToken("fi", is: .keyword, in: code)
    }

    @Test func ifElse() {
        let code = "if true; then echo a; else echo b; fi"
        expectToken("if", is: .keyword, in: code)
        expectToken("then", is: .keyword, in: code)
        expectToken("else", is: .keyword, in: code)
        expectToken("fi", is: .keyword, in: code)
    }

    @Test func forLoop() {
        let code = "for i in *.txt; do cat \"$i\"; done"
        expectToken("for", is: .keyword, in: code)
        expectToken("i", is: .type, in: code)
        expectToken("in", is: .keyword, in: code)
        expectToken("do", is: .keyword, in: code)
        expectToken("cat", is: .function, in: code)
        expectToken("done", is: .keyword, in: code)
    }

    @Test func whileLoop() {
        let code = "while true; do echo loop; done"
        expectToken("while", is: .keyword, in: code)
        expectToken("do", is: .keyword, in: code)
        expectToken("done", is: .keyword, in: code)
    }

    @Test func caseStatement() {
        let code = "case $x in a) echo a;; esac"
        expectToken("case", is: .keyword, in: code)
        expectToken("in", is: .keyword, in: code)
        expectToken("esac", is: .keyword, in: code)
    }

    @Test func functionDefinition() {
        let code = "function greet() { echo \"hi\"; }"
        expectToken("function", is: .keyword, in: code)
        expectToken("echo", is: .function, in: code)
    }
}

// MARK: - Operator Tests

@Suite("TreeSitter Bash — Operators")
struct TreeSitterBashOperatorTests {

    @Test func pipeOperator() {
        let code = "cat foo | head"
        expectToken("|", is: .operator, in: code)
    }

    @Test func andOperator() {
        let code = "make && make install"
        expectToken("&&", is: .operator, in: code)
    }

    @Test func orOperator() {
        let code = "test -f x || exit 1"
        expectToken("||", is: .operator, in: code)
    }

    @Test func redirectionOperators() {
        let code = "echo hello > output.txt"
        expectToken(">", is: .operator, in: code)
    }

    @Test func appendRedirection() {
        let code = "echo hello >> output.txt"
        expectToken(">>", is: .operator, in: code)
    }

    @Test func fileDescriptorRedirection() {
        let code = "cmd 2>&1"
        let numbers = tokens(.number, in: code)
        #expect(numbers.contains { $0.text == "2" }, "File descriptor should be a number")
    }
}

// MARK: - Comment Tests

@Suite("TreeSitter Bash — Comments")
struct TreeSitterBashCommentTests {

    @Test func lineComment() {
        let code = "echo hello # this is a comment"
        expectToken("echo", is: .function, in: code)
        expectToken("# this is a comment", is: .comment, in: code)
    }

    @Test func fullLineComment() {
        let code = "# full line comment"
        expectToken("# full line comment", is: .comment, in: code)
    }

    @Test func commentAfterSemicolon() {
        let code = "echo a; # comment"
        expectToken("echo", is: .function, in: code)
        expectToken("# comment", is: .comment, in: code)
    }
}

// MARK: - Heredoc Tests

@Suite("TreeSitter Bash — Heredocs")
struct TreeSitterBashHeredocTests {

    @Test func basicHeredoc() {
        let code = """
        cat <<EOF
        hello world
        EOF
        """
        expectToken("cat", is: .function, in: code)
        // Heredoc body should be string
        let strings = tokens(.string, in: code)
        let body = strings.first { $0.text.contains("hello world") }
        #expect(body != nil, "Heredoc body should be highlighted as string")
    }

    @Test func quotedHeredoc() {
        let code = """
        cat <<'MARKER'
        no $expansion here
        MARKER
        """
        expectToken("cat", is: .function, in: code)
    }
}

// MARK: - Command Substitution

@Suite("TreeSitter Bash — Substitution")
struct TreeSitterBashSubstitutionTests {

    @Test func dollarParenSubstitution() {
        let code = "echo $(pwd)"
        expectToken("echo", is: .function, in: code)
        expectToken("pwd", is: .function, in: code)
    }

    @Test func nestedSubstitution() {
        let code = "echo $(dirname $(pwd))"
        expectToken("echo", is: .function, in: code)
        expectToken("dirname", is: .function, in: code)
        expectToken("pwd", is: .function, in: code)
    }
}

// MARK: - Real-World Commands from Oppi Sessions

@Suite("TreeSitter Bash — Real World")
struct TreeSitterBashRealWorldTests {

    @Test func gitCommitWithMultiLineMessage() {
        // Exact pattern from the screenshot that triggered this work
        let code = """
        cd /Users/testuser/workspace/oppi && git commit -m "feat: show blue Question pill in session list
        when agent asks a question

        Add AskRequestStore to track pending ask tool
        requests per session."
        """
        expectToken("cd", is: .function, in: code)
        expectToken("&&", is: .operator, in: code)
        expectToken("git", is: .function, in: code)

        // All continuation lines must be inside the string, not commands
        let functions = tokens(.function, in: code)
        let functionNames = Set(functions.map(\.text))
        #expect(!functionNames.contains("when"), "'when' must not be a command")
        #expect(!functionNames.contains("Add"), "'Add' must not be a command")
        #expect(!functionNames.contains("requests"), "'requests' must not be a command")
        #expect(!functionNames.contains("mirroring"), "'mirroring' must not be a command")
    }

    @Test func xcodebuildPipeline() {
        let code = "xcodebuild -scheme Oppi build 2>&1 | grep -E '(passed|skipped)'"
        expectToken("xcodebuild", is: .function, in: code)
        expectToken("|", is: .operator, in: code)
        expectToken("grep", is: .function, in: code)
        expectToken("'(passed|skipped)'", is: .string, in: code)
    }

    @Test func npmScripts() {
        let code = "cd server && npm install && npm run check"
        expectToken("cd", is: .function, in: code)
        expectToken("npm", is: .function, in: code)
        let functions = tokens(.function, in: code)
        let npmCount = functions.filter { $0.text == "npm" }.count
        #expect(npmCount == 2, "Both npm invocations should be functions")
    }

    @Test func envVarsWithCommand() {
        let code = "FOO=bar BAZ=qux xcodebuild -scheme Oppi"
        expectToken("FOO", is: .type, in: code)
        expectToken("BAZ", is: .type, in: code)
        expectToken("xcodebuild", is: .function, in: code)
    }

    @Test func complexPipeline() {
        let code = "find . -name '*.swift' | xargs grep -l 'TODO' | sort | head -10"
        expectToken("find", is: .function, in: code)
        expectToken("xargs", is: .function, in: code)
        // Note: tree-sitter correctly treats 'grep' as an argument to xargs,
        // not a separate command. This is semantically correct — xargs is
        // the command, and grep is its argument.
        expectToken("sort", is: .function, in: code)
        expectToken("head", is: .function, in: code)
    }

    @Test func bashScriptSnippet() {
        let code = """
        #!/bin/bash
        set -euo pipefail
        SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        echo "Running from $SCRIPT_DIR"
        """
        // Shebang line is a comment
        expectToken("#!/bin/bash", is: .comment, in: code)
        expectToken("set", is: .function, in: code)
        expectToken("SCRIPT_DIR", is: .type, in: code)
        expectToken("echo", is: .function, in: code)
    }
}

// MARK: - Integration with SyntaxHighlighter

@Suite("TreeSitter — SyntaxHighlighter Integration")
struct TreeSitterIntegrationTests {

    @Test func shellUsesTreeSitter() {
        // Verify that SyntaxHighlighter.scanTokenRanges dispatches to tree-sitter for shell
        let code = "echo hello"
        let ranges = SyntaxHighlighter.scanTokenRanges(code, language: .shell)
        let functions = ranges.filter { $0.kind == .function }
        #expect(!functions.isEmpty, "Shell should produce function tokens via tree-sitter")
    }

    @Test func highlightPreservesText() {
        let code = "cd /tmp && echo hello"
        let result = SyntaxHighlighter.highlight(code, language: .shell)
        #expect(result.string == code, "Highlighted text must match input")
    }

    @Test func nonShellLanguagesFallBack() {
        // Other languages should still use the hand-written scanner
        let code = "let x = 42"
        let ranges = SyntaxHighlighter.scanTokenRanges(code, language: .swift)
        #expect(!ranges.isEmpty, "Swift should still produce tokens via fallback scanner")
    }

    @Test func treeSitterSupportsShell() {
        #expect(TreeSitterHighlighter.supports(.shell))
        #expect(!TreeSitterHighlighter.supports(.swift))
        #expect(!TreeSitterHighlighter.supports(.python))
        #expect(!TreeSitterHighlighter.supports(.unknown))
    }
}
