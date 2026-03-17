## Status: CONVERGED

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

### Run 1 — Fused text build + range-based syntax highlighting ✅ KEEP
Replaced per-line append with two-phase fused build:
1. Build entire text as NSMutableString, tracking per-line offsets in LineInfo structs
2. Create NSMutableAttributedString once, apply all attributes by range
3. Use `SyntaxHighlighter.scanTokenRanges()` instead of legacy `highlightLine()` per line

Eliminates: ~5000-15000 intermediate NSAttributedString objects, per-line NSMutableAttributedString copy, per-line enumerateAttribute call.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 39,572 | 17,209 | **-56.5%** |
| `diffBuild_300` | 23,660 | 10,132 | **-57.2%** |
| `diffBuild_100` | 7,905 | 3,276 | **-58.6%** |
| `diffBuild_plain_500` | 6,011 | 5,504 | **-8.4%** |

### Run 2 — Reuse original line text for syntax scan ✅ KEEP
Avoid `(text as NSString).substring(with:)` in Phase 5. Store original `line.text` strings from Phase 1 and pass them directly to `scanTokenRanges`.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 17,209 | 15,864 | **-7.8%** |

### Run 3 — Batch syntax scan with O(n) offset mapping ✅ KEEP
Instead of 500 individual `scanTokenRanges` calls, concatenate all code texts into one string (newline-separated) and scan once. Map token offsets to fused text positions via parallel lineIdx scan.

Eliminates: 500 × `truncatedCode()` overhead, 500 × `Array(text)` conversions → 1 conversion.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 15,864 | ~14,700 | **-7.5%** |

### Run 4 — Eliminate codeTexts array ✅ KEEP (cleanup)
Build the batched code NSMutableString inline during Phase 1 instead of maintaining a separate `[String]` array + `joined`. Same perf, cleaner code, one fewer allocation.

### Run 5 — Flat parallel arrays instead of LineInfo struct ❌ DISCARD
Replace LineInfo struct array with 11 flat parallel arrays. Within noise — the 11 arrays with 11 reserve+append calls have similar overhead to the struct array.

### Run 6 — Pre-allocate attribute dictionaries ❌ DISCARD
Hoist dictionary literals out of the inner loop. Within noise — Swift COW dictionaries and inline literal optimization already handle this.

### Run 7 — Cached UIColors ❌ DISCARD (too small)
~110μs out of 14,700μs (<1%). Not worth the cache invalidation complexity.

### Final Summary

| Metric | Baseline | Final | Improvement |
|--------|----------|-------|-------------|
| `diffBuild_500` | 39,572 | ~14,500 | **-63.4%** |
| `diffBuild_300` | 23,660 | ~9,500 | **-59.8%** |
| `diffBuild_100` | 7,905 | ~3,000 | **-62.0%** |
| `diffBuild_plain_500` | 6,011 | ~5,500 | **-8.5%** |

4 keeps, 3 discards across 7 experiments.

Remaining cost dominated by:
- `SyntaxHighlighter.scanTokenRanges`: Array(text) conversion + token scan (~8,500μs for 500 lines)
- NSMutableAttributedString creation from string (~1,000μs)
- addAttribute calls for gutter/lineNum/bg/spans/tap (~4,500μs, ~2500 calls)

Further gains require: C-level scanner (avoid Character abstraction), reduce addAttribute call count (hard without changing visual output).
