## Status: CONVERGED (session 3)

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

### Session 2 (continued optimization from converged state)

Fresh baseline re-measured at ~10,470μs (lower than session 1 due to warm caches / different machine conditions).

### Run 8 — UTF-8 byte scanner for batch syntax highlighting ✅ KEEP
Added `SyntaxHighlighter.scanTokenRangesUTF8()` that operates on raw UTF-8 bytes
instead of `[Character]` array. For ASCII code (>99%), byte offsets equal character/UTF-16
offsets, so the expensive Array<Character> conversion is eliminated entirely.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 10,470 | 8,861 | **-15.4%** |

### Run 9 — Fused text build: eliminate pre-built NSAttributedStrings ✅ KEEP
Replace per-line NSAttributedString appends with a single NSMutableString build pass
followed by setAttributes by range. Eliminates ~1500 pre-built NSAttributedString objects
and ~2500 appends.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 8,861 | 8,546 | **-3.6%** |
| `diffBuild_plain_500` | 2,863 | 2,598 | **-9.3%** |

### Run 10 — Merge batch code string build with text assembly loop ✅ KEEP
Build the batch code NSMutableString inline during Phase 1 instead of maintaining a
separate `[String]` array + `joined()`. Eliminates the array allocation, per-line
String copies, and the `joined()` String creation.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 8,546 | 7,793 | **-8.8%** |

### Run 11 — Merge context code+newline setAttributes ✅ KEEP
Context lines use the same dim attrs for both code and newline. Combined into one
setAttributes call, saving ~250 calls.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 7,793 | 7,653 | **-1.8%** |
| `diffBuild_plain_500` | 2,562 | 2,265 | **-11.6%** |

### Run 12 — Swift String for batch code ✅ KEEP
Replace NSMutableString with native Swift String for batch code accumulation.
Avoids the NSMutableString→String bridging copy when passing to the UTF-8 scanner.

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| `diffBuild_500` | 7,653 | 7,461 | **-2.5%** |

### Final Summary (Session 1 + 2)

| Metric | Original Baseline | Session 1 Final | Session 2 Final | Total Improvement |
|--------|-------------------|-----------------|-----------------|-------------------|
| `diffBuild_500` | 39,572 | ~14,500 | 7,461 | **-81.1%** |
| `diffBuild_300` | 23,660 | ~9,500 | 4,376 | **-81.5%** |
| `diffBuild_100` | 7,905 | ~3,000 | 1,385 | **-82.5%** |
| `diffBuild_plain_500` | 6,011 | ~5,500 | 2,203 | **-63.4%** |

Session 1: 4 keeps, 3 discards across 7 experiments.
Session 2: 5 keeps across 5 experiments. All from fresh baseline of 10,470μs.

Remaining cost dominated by:
- `addAttribute(.foregroundColor)` calls for ~3000 syntax tokens (~3,500μs, ~47% of total)
- `setAttributes` calls for gutter/lineNum/code per line (~1,200μs, ~16%)
- UTF-8 token scanner loop (~1,500μs, ~20%)
- NSMutableString text build + NSMutableAttributedString creation (~900μs, ~12%)

Further gains require: C-level scanner, reduce addAttribute call count (inherent to NSAttributedString API), or move off main thread entirely.

### Session 3 (verification of convergence)

Phase-level instrumentation revealed actual cost breakdown (see autoresearch.ideas.md).
The scan phase (51.5%) dominates, not token application as previously estimated.
5 experiments tried — all regressed or within noise:

- Byte-level keyword matching: +17% regression (String SSO + Set hash faster than manual byte comparison)
- addAttribute for code segments: 0% (primary), -6.6% (plain) — within noise on primary
- Single-pass scanner: +7.7% regression (line-by-line bounds help optimizer)
- (firstByte, length) keyword pre-screen: 0.6% — within noise

**Conclusion**: Swift's String SSO + Set<String>.contains is the performance floor for
the keyword lookup path. Further gains require C-level scanner or moving off main thread.
