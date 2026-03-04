import Testing
@testable import Oppi

@Suite("BashEmbeddedLanguageDetector")
struct BashEmbeddedLanguageDetectorTests {

    typealias Segment = BashEmbeddedLanguageDetector.Segment

    // MARK: - No embedded language

    @Test func plainBashCommand() {
        let segments = BashEmbeddedLanguageDetector.detect("ls -la /tmp")
        #expect(segments == [Segment(text: "ls -la /tmp", kind: .shell)])
    }

    @Test func emptyCommand() {
        let segments = BashEmbeddedLanguageDetector.detect("")
        #expect(segments == [Segment(text: "", kind: .shell)])
    }

    @Test func pipelineCommand() {
        let cmd = "cat file.txt | grep pattern | wc -l"
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments == [Segment(text: cmd, kind: .shell)])
    }

    // MARK: - Heredoc detection

    @Test func nodeHeredocSingleQuoted() {
        let cmd = """
        node - <<'NODE'
        const x = 1;
        console.log(x);
        NODE
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .shell)
        #expect(segments[0].text.contains("<<'NODE'"))
        #expect(segments[1].kind == .embeddedCode(.javascript))
        #expect(segments[1].text.contains("const x = 1;"))
        #expect(segments[2].kind == .shell)
        #expect(segments[2].text.contains("NODE"))
    }

    @Test func nodeHeredocDoubleQuoted() {
        let cmd = """
        node - <<"EOF"
        const y = 2;
        EOF
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func nodeHeredocUnquoted() {
        let cmd = """
        node - <<SCRIPT
        let z = 3;
        SCRIPT
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func pythonHeredoc() {
        let cmd = """
        python3 - <<'PY'
        import sys
        print(sys.version)
        PY
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.python))
        #expect(segments[1].text.contains("import sys"))
    }

    @Test func rubyHeredoc() {
        let cmd = """
        ruby - <<'RUBY'
        puts "hello"
        RUBY
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.ruby))
    }

    @Test func swiftHeredoc() {
        let cmd = """
        swift - <<'SWIFT'
        print("hello")
        SWIFT
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.swift))
    }

    @Test func heredocWithDashForm() {
        let cmd = """
        node - <<-'NODE'
        \tconst x = 1;
        \tNODE
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func heredocPreservesTrailingContent() {
        let cmd = """
        node - <<'NODE'
        console.log("hi");
        NODE
        echo "done"
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        // Shell prefix, JS body, shell suffix (marker + trailing echo)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .shell)
        #expect(segments[1].kind == .embeddedCode(.javascript))
        #expect(segments[2].kind == .shell)
        #expect(segments[2].text.contains("echo"))
    }

    @Test func unclosedHeredocTreatsRestAsEmbedded() {
        let cmd = """
        node - <<'NODE'
        const x = require('fs');
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 2)
        #expect(segments[0].kind == .shell)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func heredocWithUnknownInterpreter() {
        // If we can't determine the language, fall back to plain shell
        let cmd = """
        somecustomtool - <<'DATA'
        key=value
        DATA
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .shell)
    }

    @Test func sqlHeredoc() {
        let cmd = """
        sqlite3 mydb.db <<'SQL'
        SELECT * FROM users WHERE id = 1;
        SQL
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.sql))
    }

    // MARK: - Inline flag detection (-e / -c)

    @Test func nodeInlineE() {
        let cmd = "node -e 'const x = 1; console.log(x)'"
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .shell)
        #expect(segments[0].text.hasSuffix("'"))
        #expect(segments[1].kind == .embeddedCode(.javascript))
        #expect(segments[1].text.contains("const x = 1"))
        #expect(segments[2].kind == .shell)
        #expect(segments[2].text == "'")
    }

    @Test func pythonInlineC() {
        let cmd = "python3 -c 'import sys; print(sys.version)'"
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.python))
        #expect(segments[1].text.contains("import sys"))
    }

    @Test func nodeInlineDoubleQuoted() {
        let cmd = #"node -e "console.log('hello')""#
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func inlineFlagWithUnknownInterpreter() {
        let cmd = "sometool -e 'data here'"
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        // Unknown interpreter — no language detected, fall back to shell
        #expect(segments.count == 1)
        #expect(segments[0].kind == .shell)
    }

    @Test func rubyInlineE() {
        let cmd = "ruby -e 'puts \"hello world\"'"
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.ruby))
    }

    // MARK: - Convenience

    @Test func embeddedLanguageConvenience() {
        #expect(BashEmbeddedLanguageDetector.embeddedLanguage(in: "ls -la") == nil)

        let nodeCmd = """
        node - <<'NODE'
        const x = 1;
        NODE
        """
        #expect(BashEmbeddedLanguageDetector.embeddedLanguage(in: nodeCmd) == .javascript)
    }

    // MARK: - Edge cases

    @Test func heredocMarkerInsideString() {
        // The marker appears inside a string in the body — should not close early
        let cmd = """
        node - <<'NODE'
        const s = "NODE is not the end";
        console.log(s);
        NODE
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        // The embedded body should contain both lines
        #expect(segments[1].text.contains("NODE is not the end"))
        #expect(segments[1].text.contains("console.log"))
    }

    @Test func shortMarkerIgnored() {
        // Single-char markers (like <<X) are ignored to avoid false positives
        let cmd = """
        cat <<X
        hello
        X
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .shell)
    }

    @Test func heredocPrefersOverInlineFlag() {
        // If both patterns exist, heredoc takes priority
        let cmd = """
        node -e 'ignored' <<'NODE'
        const x = 1;
        NODE
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        // Heredoc detection wins
        let hasEmbedded = segments.contains { $0.kind == .embeddedCode(.javascript) }
        #expect(hasEmbedded)
    }

    @Test func realWorldNodeHeredoc() {
        // Realistic agent-generated command from the screenshot
        let cmd = """
        node - <<'NODE'
        const { DatabaseSync } = require('node:sqlite');
        const db = new DatabaseSync(process.env.HOME + '/.config/oppi/telemetry.db',{readonly:true});
        const from='2026-03-03 16:00:00';
        const rows=db.prepare(`SELECT ts_ms,session_id,metric,value FROM chat_metric_samples WHERE session_id IS NOT NULL`).all(from);
        console.log(JSON.stringify(rows));
        NODE
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .shell)
        #expect(segments[0].text.contains("node - <<'NODE'"))
        #expect(segments[1].kind == .embeddedCode(.javascript))
        #expect(segments[1].text.contains("DatabaseSync"))
        #expect(segments[1].text.contains("require('node:sqlite')"))
        #expect(segments[2].kind == .shell)
        #expect(segments[2].text.hasPrefix("NODE"))
    }

    @Test func denoHeredocDetectedAsTypeScript() {
        let cmd = """
        deno run - <<'TS'
        const x: number = 42;
        console.log(x);
        TS
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.typescript))
    }

    @Test func bunHeredocDetectedAsJavaScript() {
        let cmd = """
        bun - <<'BUN'
        console.log("fast");
        BUN
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.javascript))
    }

    @Test func goHeredocNotDetected() {
        // Go doesn't read from stdin via heredoc in practice,
        // but if the command has `go` before <<, it should map to .go
        let cmd = """
        go run - <<'GO'
        package main
        GO
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.go))
    }

    @Test func pipedInterpreterDetected() {
        // Interpreter after a pipe
        let cmd = """
        cat data.txt | python3 - <<'PY'
        import sys
        PY
        """
        let segments = BashEmbeddedLanguageDetector.detect(cmd)
        #expect(segments.count == 3)
        #expect(segments[1].kind == .embeddedCode(.python))
    }
}
