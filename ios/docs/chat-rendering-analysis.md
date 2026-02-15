# Chat Rendering Analysis

> Historical snapshot from pre-UIKit row migration.
> Active renderer routing is documented in `docs/chat-renderer-active-path-checklist.md`.

**Date:** February 2026
**Context:** Pi Remote iOS app chat view rendering quality and performance

## Overview

Investigation comparing pi's TUI/export rendering with the iOS SwiftUI chat view.
Goal: determine what rendering improvements are safe to make without hurting scroll
performance, and identify the fundamental limits of the SwiftUI rendering model.

## Rendering Pipeline

```
WebSocket events
  → DeltaCoalescer (33ms batching)
    → TimelineReducer (events → [ChatItem])
      → ChatView (LazyVStack + ForEach)
        → ChatItemRow (per-item dispatch)
          → MarkdownText / ToolCallRow / ThinkingRow / etc.
```

Two code paths produce the same `[ChatItem]` array:

1. **Streaming** (WebSocket live): `text_delta` → `tool_start` → `tool_output` → `tool_end`
2. **Trace reload** (`loadFromTrace`): JSONL parsed into `TraceEvent[]`, each content block separate

## Performance Benchmarks

All measurements on Apple Silicon Mac. iPhone is roughly 0.6x single-core.

| Operation | Cost | Thread | Frequency |
|---|---|---|---|
| `parseCodeBlocks` (1120 chars) | 0.05ms | Main | Every 33ms (streaming) |
| `AttributedString(markdown:)` inline (440 chars) | 0.09ms | Main | Once per finalized block |
| `AttributedString(markdown:)` full (440 chars) | 0.14ms | Main | Once per finalized block |
| `SyntaxHighlighter` (45 lines) | 0.1ms | Background | Once per code block |
| `SyntaxHighlighter` (500 lines) | 1.0ms | Background | Once per code block |
| ForEach diff (200 items, 1 changed) | 0.025ms | Main | Every 33ms |
| `processBatch` (reducer) | <0.1ms | Main | Every 33ms |

**Frame budget:** 16.7ms (60fps) or 8.3ms (120fps ProMotion)
**Total streaming frame cost:** ~2-4ms on Mac, ~4-7ms estimated on iPhone

## TUI vs SwiftUI: Fundamental Model Difference

### Terminal TUI (pi)

- **Render target:** 2D character grid (cols × rows)
- **Character placement:** O(1) — write byte to buffer at [row, col]
- **Layout:** None — monospaced grid, every char is the same width
- **Scrolling:** Terminal emulator owns it — just buffer management
- **Color:** ANSI escape codes — zero-cost attribute application
- **Diffing:** Optional — can rewrite dirty region directly
- **Text measurement:** None — width = charCount × charWidth
- **Per-frame cost:** O(dirty_chars) — typically <1ms

### SwiftUI Chat (Pi Remote)

- **Render target:** Core Animation layer tree → GPU compositing
- **Text placement:** Core Text glyph shaping + line breaking
- **Layout:** Auto Layout constraint solver (recursive)
- **Scrolling:** UIScrollView with content offset tracking
- **Color:** CALayer properties — GPU composited
- **Diffing:** ForEach identity diff → view body re-evaluation
- **Text measurement:** Core Text typesetter (the expensive part)
- **Per-frame cost:** O(visible_views × text_complexity)

The gap is the **rendering model**, not raw speed. The TUI writes bytes to buffer
offsets — zero layout. SwiftUI must shape glyphs, compute line breaks, measure
heights, solve constraints, and composite layers for every text view.

## Three Bottlenecks That Matter

### 1. Text Measurement (Core Text typesetter)

SwiftUI `Text` with attributed strings must shape glyphs, compute line breaks,
and determine intrinsic size. Cost: ~0.5-2ms per `Text` view with 200+ characters.
The TUI equivalent is 0ms (monospaced = width is charCount × charWidth).

### 2. View Hierarchy Depth

Each `ChatItemRow` → `VStack` → `HStack` → `MarkdownText` → `VStack` → `ForEach` → `Text`.
Six+ levels deep. Each level adds Auto Layout passes. `LazyVStack` helps (only visible
rows have backing views), but scrolling triggers layout for rows entering the viewport.

### 3. State Change Propagation

`@Observable` renderVersion bump → ChatView body re-evaluated → ForEach diffs all
items (O(n) Equatable checks). Changed items get body re-evaluation; unchanged items
are skipped via structural identity. But the diff itself runs every 33ms during streaming.

## What We Already Do Right

- **Streaming skips markdown parsing:** `isStreaming: true` → plain `Text()`, no `AttributedString`
- **Syntax highlighting is async:** `Task.detached(priority: .userInitiated)` off main thread
- **LazyVStack + 500 item cap:** Only ~15-20 rows rendered at once
- **Equatable + stable IDs:** Unchanged items skip body evaluation
- **DeltaCoalescer at 33ms:** Prevents per-token SwiftUI diff thrash
- **Non-reactive scroll anchor:** `ScrollAnchorState` is a class (reference type) to avoid triggering body re-evaluation
- **Debounced scroll-to-bottom:** 150ms trailing edge with post-sleep re-check

## Rendering Quality Gaps (vs /share HTML)

### 1. Markdown Prose Rendering

The `/share` HTML uses `marked.js` (full GFM) + `highlight.js`. The iOS app uses:
- **Streaming:** plain `Text()` — no formatting at all
- **Finalized:** `AttributedString(markdown:, interpretedSyntax: .inlineOnlyPreservingWhitespace)` — handles bold/italic/code/links but NOT headings, lists, blockquotes, or horizontal rules

Impact: Numbered lists render as inline text. Headings render as plain bold text.

### 2. Tool Output Expansion

HTML has two-stage expand: show first N lines, click to see all. iOS shows everything
when expanded — creates massive scroll areas for 50KB+ outputs.

### 3. Custom Tool Headers

`recall`, `remember`, `todo` show raw `argsSummary` dump. Could have custom formatting
like the core tools (bash, read, write, edit).

## Performance Impact of Proposed Improvements

### Extending markdown parser (lists, headings, blockquotes)

- **During streaming:** Zero impact — parser runs but prose uses plain `Text()`
- **After finalization:** One-time parse + `AttributedString` creation, ~0.1ms per block
- **New view types:** Each list/heading/blockquote adds a SwiftUI view, but they're
  structurally simpler than code blocks (no async highlighting, no horizontal scroll)
- **Verdict:** Safe to implement

### Two-stage tool output expansion

- **Performance:** Reduces rendered text, so strictly better
- **Memory:** Already bounded by `ToolOutputStore` caps

### AttributedString caching

- **Current:** Each body evaluation of finalized `MarkdownText` re-creates `AttributedString`
- **Fix:** Cache by content hash; skip re-parse on scroll-into-view
- **Impact:** Eliminates ~0.1ms per finalized prose block on re-render
- **Priority:** Nice-to-have, not a bottleneck

## Conclusion

Performance is not the blocker for rendering improvements. The streaming pipeline
runs at ~2-4ms per frame (well within 16.7ms budget). The quality gap is in the
**finalized rendering path** where we can afford expensive operations because they
run once per message, not per frame.

The fundamental TUI-vs-SwiftUI gap (no text measurement, no layout, no diffing) is
inherent to the platform. We can't close it. But we don't need to — the frame
budget gives us plenty of headroom for richer rendering.
