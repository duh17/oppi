# Autoresearch: DiffAttributedStringBuilder Performance

## Objective

Optimize `DiffAttributedStringBuilder.build()` — the function that converts structured diff hunks into a syntax-highlighted `NSAttributedString` for the unified diff view.

This runs on the **main thread** in `UIViewRepresentable.makeUIView()` for both `UnifiedDiffTextView` and `UnifiedDiffTextSegment`. For large diffs (500+ lines), it causes 9000+ ms app hangs (Sentry APPLE-IOS-1X).

Workload: realistic Swift diff hunks at 100, 300, and 500 lines with a mix of context (50%), removed (20%), added (20%), and removed+added pairs (10%). Some lines include word-level highlight spans.

## Metrics

- **Primary**: `diffBuild_500` (μs, lower is better) — full build for 500 diff lines of Swift
- **Secondary**: `diffBuild_300`, `diffBuild_100`, `diffBuild_plain_500` (unknown language, no syntax highlighting)

## How to Run

```bash
cd ios && ./autoresearch.sh
```

Outputs `METRIC name=value` lines parsed from xcodebuild test output.

## Files in Scope

| File | What |
|------|------|
| `Oppi/Core/Views/DiffAttributedStringBuilder.swift` | Target: builds NSAttributedString from diff hunks with syntax highlighting, gutter, backgrounds, word spans, tap metadata |
| `Oppi/Core/Formatting/SyntaxHighlighter.swift` | Token scanner — has both legacy `highlightLine()` (per-token append) and optimized `scanTokenRanges()` (range-based). The builder currently uses the legacy path. |
| `OppiTests/Perf/DiffBuilderPerfBench.swift` | Benchmark harness |

## Off Limits

- `UnifiedDiffView.swift` — view layer (threading fix is separate from perf optimization)
- `AnnotatedDiffView.swift` — segmentation logic, not perf target
- `WorkspaceReview.swift` — model types
- Visual output must remain identical (same colors, gutter layout, backgrounds, word spans, tap metadata)

## Constraints

- Output must be visually identical (same foreground colors, background tints, word-level spans, tap info attributes)
- All existing diff-related tests must pass
- No new dependencies
- The `diffLineKindAttributeKey` and `diffLineTapInfoKey` custom attributes must be preserved (used by layout managers and tap handlers)
- Must remain callable from `@MainActor` context

## Architecture Notes

### Current Cost Centers

For each diff line, the builder currently:
1. Creates 3 `NSAttributedString` objects: gutter prefix ("▎+ "), line numbers, and (for newlines) another one
2. Calls `SyntaxHighlighter.highlightLine()` — the **legacy** per-token append path. Each call: `Array(line)` conversion, token scan, per-token NSAttributedString creation + append. For 500 lines: ~5000-15000 intermediate objects.
3. Wraps result in `NSMutableAttributedString(attributedString:)` copy
4. Calls `addAttributes` for font + paragraphStyle on the full range
5. Calls `enumerateAttribute(.foregroundColor)` to fill nil ranges with default fg
6. Appends gutter + code + newline to the growing result
7. Applies row-level attributes: diffLineKind, backgroundColor, word spans, tap info

### Known Optimized APIs Available (from prior autoresearch)

- `SyntaxHighlighter.scanTokenRanges(code, language:)` — returns `[TokenRange]` with `(location, length, kind)`. Range-based, no intermediate NSAttributedString creation. 60% faster than `highlightLine()`.
- `SyntaxHighlighter.color(for: TokenKind)` — resolves a token kind to its cached UIColor.
- Fused text assembly pattern: build NSMutableString first, convert once, apply attributes by range.
- `beginEditing()/endEditing()` for batched attribute mutations.

### Optimization Strategy

Apply the same "fused build" pattern that worked for `makeCodeAttributedText`:
1. First pass: build entire text as NSMutableString, tracking per-line offset arrays (gutter start, lineNum start, code start, row start/end)
2. Create NSMutableAttributedString from string with default attributes
3. Apply gutter/lineNum colors by range using offset arrays
4. For each line's code region, use `scanTokenRanges` on the line text, then map token offsets to fused text positions
5. Apply row-level attributes (backgrounds, diffLineKind, tap info) by range
6. Wrap in beginEditing/endEditing

## What's Been Tried

### Run 0 — Baseline
| Metric | Value |
|--------|-------|
| `diffBuild_500` | 39,572μs |
| `diffBuild_300` | 23,660μs |
| `diffBuild_100` | 7,905μs |
| `diffBuild_plain_500` | 6,011μs |

Cost breakdown (estimated from 500-line numbers):
- Syntax highlighting (highlightLine × 500): ~33,500μs (85% — this is the legacy per-token append path)
- Gutter/line number assembly + attributed string appends: ~6,000μs (15%)
- Without syntax highlighting (plain): 6,011μs baseline
