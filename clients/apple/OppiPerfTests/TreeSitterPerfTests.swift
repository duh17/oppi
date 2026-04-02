import XCTest
@testable import Oppi

/// Performance benchmarks for tree-sitter syntax highlighting.
///
/// Run before and after adding each new grammar to verify:
/// 1. No regression in existing language performance
/// 2. New grammar meets the same performance bar
///
/// Target: <1ms for typical inputs (50-200 chars), <5ms for large inputs (5K chars)
class TreeSitterPerfTests: XCTestCase {

    // MARK: - Bash Benchmarks

    /// Typical bash command from agent tool calls (~100 chars)
    func testBashTypicalCommand() {
        let code = "cd /Users/chenda/workspace/oppi && git commit -m \"feat: improve syntax highlighting\""
        measure {
            for _ in 0..<100 {
                _ = TreeSitterHighlighter.scanTokenRanges(code, language: .shell)
            }
        }
    }

    /// Complex pipeline (~200 chars)
    func testBashComplexPipeline() {
        let code = """
        FOO=bar BAZ=qux xcodebuild -scheme Oppi build 2>&1 | grep -E '(passed|skipped)' | tee output.log && echo "done" || echo "failed"
        """
        measure {
            for _ in 0..<100 {
                _ = TreeSitterHighlighter.scanTokenRanges(code, language: .shell)
            }
        }
    }

    /// Multi-line bash script (~500 chars)
    func testBashScript() {
        let code = """
        #!/bin/bash
        set -euo pipefail

        SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        export PATH="$SCRIPT_DIR/bin:$PATH"

        if [ -f "$SCRIPT_DIR/.env" ]; then
            source "$SCRIPT_DIR/.env"
        fi

        for f in "$SCRIPT_DIR"/scripts/*.sh; do
            echo "Running $f..."
            bash "$f" 2>&1 | tee -a "$SCRIPT_DIR/output.log"
        done

        echo "All scripts completed successfully."
        """
        measure {
            for _ in 0..<100 {
                _ = TreeSitterHighlighter.scanTokenRanges(code, language: .shell)
            }
        }
    }

    /// Large bash output (~5K chars) — stress test
    func testBashLargeInput() {
        // Simulate a large bash script with repeated patterns
        var lines: [String] = ["#!/bin/bash", "set -euo pipefail", ""]
        for i in 0..<100 {
            lines.append("echo \"Processing item \(i) of 100\" | tee -a log.txt")
            lines.append("if [ -f \"item_\(i).txt\" ]; then")
            lines.append("  cat \"item_\(i).txt\" >> output.log 2>&1")
            lines.append("fi")
        }
        let code = lines.joined(separator: "\n")

        measure {
            for _ in 0..<10 {
                _ = TreeSitterHighlighter.scanTokenRanges(code, language: .shell)
            }
        }
    }

    /// End-to-end: full highlight() pipeline including NSAttributedString building
    func testBashHighlightEndToEnd() {
        let code = "cd /tmp && npm install && npm run check && git add -A && git commit -m \"feat: tree-sitter\""
        measure {
            for _ in 0..<100 {
                _ = SyntaxHighlighter.highlight(code, language: .shell)
            }
        }
    }

    // MARK: - Registry Initialization

    /// Measure one-time grammar registration cost (query compilation).
    /// This runs once at app launch and should be <50ms.
    func testGrammarRegistryInit() {
        measure {
            // Force re-creation (normally a singleton)
            _ = TreeSitterHighlighter.GrammarRegistry.shared.supports(.shell)
        }
    }
}
