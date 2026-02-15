# Main Thread Blocker Audit — Chat View

> Feb 9, 2026. Systematic audit of every code path that could block the main thread
> during scrolling or streaming in the chat timeline.

## Severity Legend
- **CRITICAL**: Can freeze scrolling for >100ms. Fix immediately.
- **MODERATE**: Can cause frame drops (>16ms on main). Fix before ship.
- **LOW**: Theoretically expensive but guarded. Monitor.

---

## CRITICAL: ImageAttachment.decodedImage in view body

**Where**: `UserMessageBubble` → `ForEach(images)` → `attachment.decodedImage`

**Problem**: `decodedImage` is a computed property that calls `Data(base64Encoded:)` +
`UIImage(data:)` synchronously — every time SwiftUI evaluates the body. A 500KB JPEG
is ~670KB base64; decoding that to a UIImage takes 5-30ms on main thread. With 3 images
in a single user message, that's up to 90ms per body evaluation.

Worse: LazyVStack recycles views on scroll, so every scroll through a message with
images re-triggers decoding from base64 scratch.

**Fix**: Cache the decoded `UIImage` off main thread. Either:
1. Add `@State private var decoded: UIImage?` with `.task { decoded = await decode() }`
2. Or add a `decodedImageCache` dictionary keyed by data hash to `ImageAttachment`

---

## CRITICAL: ImageExtractor.extract regex in ToolOutputContent body

**Where**: `ToolOutputContent.body` → `ImageExtractor.extract(from: output)`

**Problem**: The regex `data:image\/([a-zA-Z0-9+.-]+);base64,([A-Za-z0-9+\/=\n\r]+)/`
runs on the *full* tool output string in the view body. A read tool returning a 500KB
image has a ~670KB base64 string. The regex engine must scan the entire string, and
the capture group `([A-Za-z0-9+\/=\n\r]+)` matches the full base64 blob — that's
O(n) regex matching on potentially megabyte-scale strings, synchronously in `body`.

Additionally called in `expandedContent` at line 519: `ImageExtractor.extract(from: fullOutput)`
— this runs on every body evaluation of expanded Read tool rows.

**Fix**: 
1. Cache the extraction result. `@State private var extractedImages: [ExtractedImage]?`
   with `.task(id: output.count) { extractedImages = ImageExtractor.extract(from: output) }`
2. Or move to a pre-computed flag: when `ToolOutputStore.append` is called, check if the
   chunk contains `data:image/` and set a flag on the tool item.

---

## CRITICAL: DiffEngine.compute in DiffContentView init

**Where**: `DiffContentView.init` calls `DiffEngine.compute(old:, new:)` synchronously.

**Problem**: LCS diff is O(n*m) where n,m are line counts. The `maxLcsCells = 250_000`
guard means up to 250K iterations in the init. For a 500×500 line edit (unlikely but
possible with large file writes), that's 250K cell allocations + comparisons on main
thread during view init — which happens when the user *expands* an Edit tool row, AND
when LazyVStack recycles the view on scroll.

For typical edits (1-50 lines), this is fine. But the guard allows up to 500 lines
which could stall.

**Fix**: Compute diff asynchronously like syntax highlighting:
```swift
@State private var diffLines: [DiffLine]?
.task(id: "\(oldText.count)-\(newText.count)") {
    diffLines = await Task.detached {
        DiffEngine.compute(old: oldText, new: newText)
    }.value
}
```

---

## MODERATE: JSONSerialization in JSONFileView computed property

**Where**: `JSONFileView.prettyContent` → `JSONSerialization.jsonObject` + `.data(withJSONObject:)`

**Problem**: Computed property called from `body` via `displayLines`. Parses the entire
JSON string into Foundation objects, then re-serializes with pretty printing. For a 50KB
JSON file (common for package.json, tsconfig), this is 2-5ms. For 256KB (ToolOutputStore
cap), could be 10-20ms.

Somewhat mitigated: this only fires when the tool row is expanded AND the file is JSON.
But it re-fires on every body evaluation (no caching).

**Fix**: Cache the pretty-printed result:
```swift
@State private var prettyResult: String?
.task(id: content.count) {
    prettyResult = await Task.detached { prettyPrint(content) }.value
}
```

---

## MODERATE: ANSIParser.attributedString in ToolOutputContent body

**Where**: `ToolOutputContent.body` → `ANSIParser.attributedString(from: displayText)`

**Problem**: Creates an `AttributedString` by scanning the entire text character-by-character
with regex matching at each position. The `displayText` is capped at `prefix(2000)` chars,
and the regex is pre-compiled (`static let`), so worst case is ~2-5ms. But this runs in
the view body, re-evaluated on every render.

**Fix**: Cache the result:
```swift
@State private var ansiAttributed: AttributedString?
.task(id: output.count) { ansiAttributed = ANSIParser.attributedString(from: ...) }
```

---

## MODERATE: parseCodeBlocks during streaming

**Where**: `MarkdownText.currentBlocks` → `parseCodeBlocks(content)` when cache is stale.

**Problem**: When `content.count` changes (every 33ms during streaming), the cache is
stale and `currentBlocks` calls `parseCodeBlocks` synchronously in the body getter. The
parser is O(n) line scanning, so for a 5000-char assistant message with 3 code blocks,
it's ~0.5ms. Not critical alone, but it's on the hot path during streaming.

The `onChange` handler also calls `refreshBlocksIfNeeded` which does the same parse —
so it runs twice per content change: once in body (sync fallback), once in onChange.

**Fix**: Already partially mitigated by caching. The double-parse could be avoided by
making `currentBlocks` return `cachedBlocks` even when stale (showing slightly old data
for one frame) and letting `onChange` be the only updater.

---

## LOW: ImageBlobView.decodeImage in body

**Where**: `ImageBlobView.body` → `decodeImage()` → `Data(base64Encoded:)` + `UIImage(data:)`

**Problem**: Same pattern as `ImageAttachment.decodedImage` but only for tool output images.
These are typically screenshots (300-500KB base64 → 200-350KB raw). Decoding takes 5-15ms.

Mitigated: ImageBlobView is only rendered inside expanded tool rows (user must tap to expand)
and behind `if isExpanded` in ToolCallRow. Not in the scroll hot path unless expanded.

**Fix**: Cache with `@State` + `.task`:
```swift
@State private var uiImage: UIImage?
.task { uiImage = await Task.detached { decodeImage() }.value }
```

---

## LOW: SyntaxHighlighter in CodeBlockView

**Where**: `CodeBlockView.task(id:)` → `Task.detached { SyntaxHighlighter.highlight(...) }`

**Status**: Already async — correctly offloaded to `.detached` task. No main thread concern.

---

## LOW: SyntaxHighlighter in CodeFileView / JSONFileView

**Where**: `.task(id:)` → `Task.detached { SyntaxHighlighter.highlight(...) }`

**Status**: Already async. Correct.

---

## LOW: DiffContentView diffRow with syntax highlighting

**Where**: `DiffContentView.diffRow` calls `SyntaxHighlighter.highlight` for each line.

**Problem**: If there are 50 diff lines and each has highlighting, that's 50 synchronous
highlight calls during body evaluation.

**Mitigated by**: Diff lines are typically short (one line each), and highlighting is O(n)
per line. 50 short lines is ~1-2ms total. Also only visible when expanded.

**Fix**: Consider batch highlighting the full diff as one text block, then splitting.

---

## Summary — Priority Fix Order

| # | Issue | Severity | Location | Fix Complexity |
|---|-------|----------|----------|---------------|
| 1 | ImageAttachment.decodedImage in body | CRITICAL | UserMessageBubble | Low — @State + .task |
| 2 | ImageExtractor.extract regex in body | CRITICAL | ToolOutputContent, expandedContent | Low — @State + .task |
| 3 | DiffEngine.compute in init | CRITICAL | DiffContentView | Low — @State + .task |
| 4 | JSONSerialization in computed prop | MODERATE | JSONFileView | Low — @State + .task |
| 5 | ANSIParser.attributedString in body | MODERATE | ToolOutputContent | Low — @State + .task |
| 6 | parseCodeBlocks double-parse | MODERATE | MarkdownText | Low — return stale cache |
| 7 | ImageBlobView.decodeImage in body | LOW | ImageBlobView | Low — @State + .task |
