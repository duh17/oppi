# Syntax Highlighting

Architecture and status of syntax highlighting across all supported languages and renderers.

## Architecture

Shared tokens live in OppiCore. Each Apple client paints those tokens itself.

```
OppiCore token provider
  |
  +-- TreeSitterHighlighter     Query-based tokens (bash is registered)
  |     +-- GrammarRegistry     Caches Language + compiled highlights Query
  |     +-- highlights.scm      Loaded from each grammar's SPM resource bundle
  |     +-- captureKindMap      Shared @capture-name -> TokenKind table
  |     +-- resolvedTokenRanges / resolvedTokenRangesUTF8
  |
  +-- SyntaxTokenScanner        Hand-written fallback + UTF-8 ASCII path
  |     +-- truncatedCode       Sole token-work budget (10,000 lines)
  |     +-- scanTokenRangesByCharacter
  |     +-- scanLineRangesSlice / scanLineRangesUTF8Slice
  |     +-- scanJSONRanges / scanXMLRanges / scanDiffRanges
  |
  +-- BashEmbeddedLanguageDetector  Heredocs / inline scripts in bash

Platform painters
  +-- iOS SyntaxHighlighter     Tokens -> NSAttributedString (UIColor, theme cache)
  +-- Mac MacSyntaxHighlighter  Tokens -> NSAttributedString (NSColor, Mac fonts)
  +-- iOS DiffAttributedStringBuilder  Per-hunk projections; cached painter colors
  +-- iOS ToolRowTextRenderer   Guttered tool-row paint from the same tokens/colors

Transport
  +-- SendableNSAttributedString  Immutable NSAttributedString across Task.detached
```

## Entry Points

Token ranges come from OppiCore. Painters and the diff builder consume those ranges;
they do not re-scan or invent a second token→color table.

| Method | Owner | Used by |
|---|---|---|
| `TreeSitterHighlighter.resolvedTokenRanges` | OppiCore | iOS/Mac painters, tool-row gutters |
| `TreeSitterHighlighter.resolvedTokenRangesUTF8` | OppiCore | Diff builder (tree-sitter or UTF-8 fallback) |
| `SyntaxHighlighter.highlight` | iOS painter | Markdown fences, fullscreen, share/export, bash command |
| `MacSyntaxHighlighter.attributedCode` | Mac painter | Mac timeline / document column |

`resolvedTokenRanges` tries tree-sitter first, then `SyntaxTokenScanner`. Public `SyntaxTokenRange` offsets are always UTF-16 code units, matching `NSRange`, `NSString`, and tree-sitter captures. Displayed source is the full input; only token work is bounded.

## Token Kinds

Nine token types map to theme colors. Every character gets one of these:

| TokenKind | Theme Color | Purpose |
|---|---|---|
| `.variable` | themeSyntaxVariable | Default/unstyled text |
| `.comment` | themeSyntaxComment | Comments |
| `.keyword` | themeSyntaxKeyword | Language keywords |
| `.string` | themeSyntaxString | String literals, heredocs |
| `.number` | themeSyntaxNumber | Numbers, constants, file descriptors |
| `.type` | themeSyntaxType | Types, variables, properties |
| `.function` | themeSyntaxFunction | Command/function names |
| `.operator` | themeSyntaxOperator | Operators: &&, ||, |, >, etc. |
| `.punctuation` | themeSyntaxPunctuation | Brackets, delimiters |

## Language Status

### tree-sitter (Query-based, conforms to upstream highlights.scm)

| Language | SyntaxLanguage | SPM Package | Perf (100 calls, sim) | Tests | Status |
|---|---|---|---|---|---|
| Bash/Shell | `.shell` | tree-sitter-bash 0.25.0 | 0.07ms/call typical, 0.98ms/5K | 49 | Shipped |

### Hand-written scanner (line-by-line keyword/comment/string detection)

| Language | SyntaxLanguage | Approach | Notes |
|---|---|---|---|
| Swift | `.swift` | keywords + comment + string | |
| TypeScript | `.typescript` | keywords + comment + string | Shared with JS |
| JavaScript | `.javascript` | keywords + comment + string | Shared with TS |
| Python | `.python` | keywords + # comment + string | |
| Go | `.go` | keywords + comment + string | |
| Rust | `.rust` | keywords + comment + string | |
| Ruby | `.ruby` | keywords + # comment + string | |
| C/C++ | `.c`, `.cpp` | keywords + comment + preprocessor | |
| Java | `.java` | keywords + comment + string | |
| Kotlin | `.kotlin` | keywords + comment + string | |
| Zig | `.zig` | keywords + comment + string | |
| SQL | `.sql` | keywords + -- comment | Case-insensitive |
| Protobuf | `.protobuf` | keywords + comment | |
| GraphQL | `.graphql` | keywords + comment | |
| HTML | `.html` | (via XML scanner) | |
| CSS | `.css` | keywords + comment | |
| YAML | `.yaml` | # comment only | |
| TOML | `.toml` | # comment only | |

### Dedicated scanners

| Language | SyntaxLanguage | Scanner | Notes |
|---|---|---|---|
| JSON | `.json` | `scanJSONRanges` | Keys as .type, values as .string |
| XML | `.xml` | `scanXMLRanges` | Tags, attributes, entities, CDATA |
| Diff | `.diff` | `scanDiffRanges` | +/- lines, @@ headers |

### Document renderers (separate rendering pipeline, not token-based)

| Format | SyntaxLanguage | Renderer | Notes |
|---|---|---|---|
| LaTeX | `.latex` | `MathCoreGraphicsRenderer` | CGContext-based math rendering |
| Org Mode | `.orgMode` | `OrgAttributedStringRenderer` | Parsed AST -> attributed string |
| Mermaid | `.mermaid` | `MermaidFlowchartRenderer` et al. | Multiple diagram types |
| Graphviz | `.dot` | Graphviz renderer | Graph layout via SugiyamaLayout |

## Adding a tree-sitter Grammar

### 1. Add SPM dependency

```yaml
# project.yml packages:
tree-sitter-python:
  url: https://github.com/tree-sitter/tree-sitter-python
  from: "0.23.0"
```

```yaml
# Oppi target dependencies:
- package: tree-sitter-python
  product: TreeSitterPython
```

### 2. Register the grammar

```swift
// TreeSitterHighlighter.swift — GrammarRegistry.registerAll()
import TreeSitterPython
// ...
register(.python, tsLanguage: tree_sitter_python(), name: "Python")
```

### 3. Add conformance tests

Create `OppiTests/Parsers/TreeSitter<Lang>HighlightTests.swift` with:
- Basic constructs: keywords, strings, comments, functions
- Multi-line constructs (the whole point of tree-sitter)
- Real-world code snippets from actual agent sessions
- Integration test: `SyntaxHighlighter.highlight()` produces expected colors

### 4. Add performance benchmark

Add to `OppiPerfTests/TreeSitterPerfTests.swift`:
- Typical input (~100 chars): target <0.1ms/call
- Large input (~5K chars): target <1ms/call
- End-to-end `highlight()`: target <0.2ms/call

### 5. Verify

```bash
# Conformance tests
sim-pool.sh run -- xcodebuild ... -scheme OppiUnitTests test -only-testing:OppiTests/TreeSitter<Lang>Tests

# Perf tests
sim-pool.sh run -- xcodebuild ... test -only-testing:OppiPerfTests/TreeSitterPerfTests

# Full regression
sim-pool.sh run -- xcodebuild ... -scheme OppiUnitTests test -only-testing:OppiTests
```

## tree-sitter Capture Name Mapping

The `captureKindMap` in `TreeSitterHighlighter` maps standard tree-sitter capture names
to our `TokenKind`. This table is shared across all languages:

```
@comment        -> .comment
@string         -> .string
@keyword        -> .keyword
@function       -> .function
@function.call  -> .function
@variable       -> .variable
@property       -> .type
@type           -> .type
@number         -> .number
@constant       -> .number
@operator       -> .operator
@punctuation    -> .punctuation
@tag            -> .keyword
@tag.attribute  -> .type
```

Dotted names fall back to their parent: `@keyword.function` tries exact match first,
then falls back to `@keyword`. Unmapped captures get no color (default foreground).

## Supplementary Patterns

Some upstream `highlights.scm` files are incomplete. We append supplementary
patterns after loading the upstream query. These are clearly commented:

```scheme
;; Oppi supplements -- operators missing from upstream highlights.scm
["||" "|&" "<<<" ">|" "&>" "&>>" ";;" ";&" ";;&"] @operator
```

Supplements should be minimal and tracked. If upstream adds the pattern later,
our supplement becomes a no-op (duplicate patterns are harmless in tree-sitter).

## Performance Budget

All highlighting runs on `Task.detached` (off main thread). Targets:

| Input size | Target per-call | Notes |
|---|---|---|
| Typical (50-200 chars) | <0.2ms | Most bash commands, code snippets |
| Medium (500-2K chars) | <0.5ms | Scripts, file contents |
| Large (5K+ chars) | <2ms | Full file highlighting |
| Token work budget | 10,000 lines | `SyntaxTokenScanner.truncatedCode`; display is not truncated |

Measured on simulator (M-series Mac). iPhone is ~2-4x slower.
All current tree-sitter grammars meet these targets. Painters keep complete source; the tail past the budget stays the base (variable) color.

## Files

| File | Purpose |
|---|---|
| `OppiCore/Formatting/TreeSitterHighlighter.swift` | Query-based tree-sitter highlighting + registry |
| `OppiCore/Formatting/SyntaxTokenScanner.swift` | Hand-written fallback + UTF-8 scanners + token budget |
| `Oppi/Core/Formatting/SyntaxHighlighter.swift` | iOS painter: theme colors + NSAttributedString |
| `OppiMac/Formatting/MacSyntaxHighlighter.swift` | Mac painter: NSColor, Mac fonts, no baked gutters |
| `OppiCore/Formatting/SyntaxKeywords.swift` | Keyword sets for hand-written scanners |
| `OppiCore/Formatting/BashEmbeddedLanguageDetector.swift` | Heredoc/inline script detection |
| `Oppi/Core/Formatting/FullScreenCodeHighlighter.swift` | `SendableNSAttributedString` transport |
| `ANSIParser.swift` | ANSI escape code -> attributed string |
| `TreeSitterBashHighlightTests.swift` | Bash conformance tests (49 tests) |
| `TreeSitterPerfTests.swift` | Performance benchmarks |
| `SyntaxHighlighterTests.swift` | iOS painter + scanner integration tests |
