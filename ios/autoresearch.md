## Status: CONVERGED

# Autoresearch: Syntax Highlighting Pipeline Performance

## Objective

Optimize the `SyntaxHighlighter` and `ToolRowTextRenderer.makeCodeAttributedText` pipeline that converts raw source code into syntax-highlighted NSAttributedString with line numbers and gutter.

This pipeline runs on the main thread when a code tool finishes streaming (transition from plain text to highlighted). It also runs on cell reconfigure when the render cache misses. Reducing its cost enables tighter frame budgets and potentially live highlighting during streaming.

Workload: realistic Swift source code at 100 and 500 lines (the 500-line cap is enforced in production).

## Metrics

- **Primary**: `codeAttr_500` (μs, lower is better) — full `makeCodeAttributedText` pipeline for 500 lines of Swift
- **Secondary**: `highlight_500`, `highlightLines_500`, `codeAttr_100`, `highlight_100`, `highlightLines_100`, `highlight_json_500`, `highlight_shell_100`

## How to Run

```bash
cd ios && ./autoresearch.sh
```

Outputs `METRIC name=value` lines parsed from xcodebuild test output.

## Files in Scope

| File | What |
|------|------|
| `Oppi/Core/Formatting/SyntaxHighlighter.swift` | Token scanner: appendHighlightedLine, highlightLines, highlight, highlightJSON, shell scanner |
| `Oppi/Features/Chat/Timeline/Tool/ToolRowTextRenderer.swift` | `makeCodeAttributedText` — gutter assembly + highlight + NSAttributedString build |
| `OppiTests/Perf/SyntaxHighlightPerfBench.swift` | Benchmark harness (outputs METRIC lines) |

## Off Limits

- `ToolRowCodeRenderStrategy.swift` — render policy / tier logic (architectural, not perf target)
- `ToolRowRenderCache.swift` — cache layer (already instant on hit)
- `StreamingRenderPolicy.swift` — tier decision logic
- Visual output must remain identical (same token colors, same gutter format)

## Constraints

- All existing tests must pass: `SyntaxHighlighterTests`, `ToolRowCodeRenderStrategyTests`, `RenderStrategyPerfTests`
- No new dependencies
- Output must be visually identical (same foreground colors per token type, same gutter layout)
- 500-line cap stays (SyntaxHighlighter.maxLines)
- Must remain @MainActor-safe (no background thread requirements)

## Architecture Notes

### SyntaxHighlighter

Token-based line scanner. For each line: scans characters left-to-right, classifies tokens (comment, keyword, string, number, type, variable, punctuation, operator), appends NSAttributedString per token. Block comment state carried across lines.

`TokenAttrs` struct pre-computes UIColor dictionaries once per top-level call — avoids repeated `UIColor(Color)` conversions.

Key cost centers:
- `Array(line)` — copies each line's characters into a [Character] array
- Per-token `NSAttributedString(string:attributes:)` creation — 10-30 per line × 500 lines = 5000-15000 intermediate objects
- `NSMutableAttributedString.append()` — O(1) amortized but each call has overhead

### makeCodeAttributedText

For each line:
1. `paddedLineNumber` via `String(format:)` — C sprintf overhead per line
2. Three NSAttributedString allocations: line number, separator "│ ", code content
3. Each highlighted line gets `addAttributes` for font + paragraphStyle, then `enumerateAttribute` for missing foregroundColor
4. Final newline append between lines

### JSON Highlighter

Separate path — highlights whole text as one pass (no per-line split). Already efficient for its use case.

### Shell Highlighter

Separate scanner with command/option/variable/operator detection. Same per-token NSAttributedString pattern.

## What's Been Tried

(Updated as experiments accumulate)

### Run 0 — Baseline
| Metric | Value |
|--------|-------|
| `codeAttr_500` | 16,528μs |
| `codeAttr_100` | 3,210μs |
| `highlight_500` | 9,783μs |
| `highlight_100` | 1,878μs |
| `highlightLines_500` | 9,873μs |
| `highlightLines_100` | 1,887μs |
| `highlight_json_500` | 5,778μs |
| `highlight_shell_100` | 2,248μs |

Cost breakdown (estimated from 500-line numbers):
- SyntaxHighlighter.highlight alone: ~9,800μs (59% of codeAttr_500)
- Gutter + assembly overhead: ~6,700μs (41% of codeAttr_500)
- highlightLines ≈ highlight (same core work, just splits per-line)

### Run 1 — Range-based syntax highlighting ✅ KEEP
Replaced per-token `NSAttributedString(string:attributes:)` creation + `append()` with:
1. Create one `NSMutableAttributedString` from full text with default (variable) color
2. Run scanner to record `(offset, length, tokenKind)` tuples
3. Apply non-default foreground colors by `NSRange`

Eliminates ~10,000 intermediate NSAttributedString allocations for 500 lines.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `codeAttr_500` | 16,528 | 9,830 | **-40.5%** |
| `highlight_500` | 9,783 | 3,823 | **-60.9%** |
| `highlightLines_500` | 9,873 | 4,802 | **-51.4%** |
| `codeAttr_100` | 3,210 | 1,963 | **-38.8%** |
| `highlight_100` | 1,878 | 741 | **-60.5%** |
| `highlight_shell_100` | 2,248 | 1,130 | **-49.7%** |

### Run 4 — Single character array scan ✅ KEEP
Convert entire text to `[Character]` once, find line boundaries by newline scan,
pass `(allChars, start, end)` bounds to scanner. Eliminates 500 per-line heap
allocations. Scanner functions rewritten to work on slices with absolute indices.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `codeAttr_500` | 7,372 | 6,268 | **-15.0%** |
| `highlight_500` | ~3,800 | 3,472 | **-9.2%** |
| `codeAttr_100` | 1,401 | 1,212 | **-13.5%** |

### Run 5 — Cache TokenAttrs ✅ KEEP
Cache the 9 UIColor(Color) conversions in a static var. Avoids redundant
conversions across sequential highlight calls. `codeAttr_500`: 6,268→5,929 (-5.4%).

### Run 6 — Avoid Substring→String copy + String(format:) ✅ KEEP
Replace `(lineStr as NSString).length` with `rawLine.utf16.count` on Substring.
Replace `String(format:)` sprintf with manual padding. `codeAttr_500`: 5,929→5,630 (-5.0%).

### Run 7 — Pre-build line number strings ❌ DISCARD
Pre-compute all gutter strings in an array. Within noise after Run 6's sprintf removal.

### Run 8 — Build NSMutableAttributedString directly (no NSMutableString) ❌ DISCARD
Using `result.mutableString.append()` triggers internal attribute bookkeeping per append,
slower than building plain NSMutableString then converting.

### Run 8b — beginEditing/endEditing ✅ KEEP (marginal)
Wrap all attribute mutations in beginEditing/endEditing. `codeAttr_500`: 5,630→5,539 (-1.6%).

### Final Summary

| Metric | Baseline | Final | Improvement |
|--------|----------|-------|-------------|
| `codeAttr_500` | 16,528 | ~5,600 | **-66.1%** |
| `highlight_500` | 9,783 | ~3,450 | **-64.7%** |
| `codeAttr_100` | 3,210 | ~1,100 | **-65.7%** |
| `highlight_100` | 1,878 | ~660 | **-64.9%** |
| `highlight_shell_100` | 2,248 | ~1,030 | **-54.2%** |
| `highlight_json_500` | 5,778 | ~5,600 | **-3.1%** (already efficient) |

6 keeps, 3 discards across 9 experiments.

Remaining cost is dominated by:
- `Array(truncated)` character conversion: ~1,000μs for 500 lines (irreducible without C scanner)
- NSMutableAttributedString creation from string: ~1,000μs (Foundation overhead)
- `addAttribute` calls for gutter + tokens: ~1,500μs (~1500 calls × ~1μs each)

Further gains require: C-level scanner (avoid Character abstraction), or custom
attributed text representation (avoid NSMutableAttributedString overhead).

### Run 2 — Fused gutter + highlight single-pass (v1) ❌ DISCARD
Tried building full guttered text as one string with token range mapping. Two problems:
1. Token→line mapping loop was O(tokens × lines) = O(n²): 9,830→54,514μs
2. Swift String `+=` and `.utf16.count` calls were O(n) each on growing string

### Run 3 — Fused gutter + highlight (v2, fixed) ✅ KEEP
Fixed Run 2 issues:
- NSMutableString for text assembly (avoids COW)
- Manual UTF-16 position tracking (avoids O(n) `.utf16.count`)
- Parallel lineIdx scan for O(tokens + lines) token mapping
- Pre-allocated flat arrays instead of inline struct + tuples

Eliminates per-line: NSMutableAttributedString copy, addAttributes, enumerateAttribute, 2× gutter NSAttributedString allocs.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `codeAttr_500` | 9,830 | 7,372 | **-25.0%** |
| `codeAttr_100` | 1,963 | 1,401 | **-28.6%** |
