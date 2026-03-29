# Inline Rendering — Remaining Ideas

## Table Export (needs research)
- Research agent investigating Google Docs, Word, Pages, Notion, Obsidian, GitHub
- Key question: wrap text, scale down, clip, or landscape?
- See `table-export-behavior.md` for findings
- Implementation: likely add export mode to `NativeTableBlockView` similar to `synchronousRendering` for mermaid

## Privacy Mitigations for Online Images
- Currently auto-loads all HTTPS URLs (tracking pixels, IP leaks)
- Options: tap-to-load placeholder, domain allowlist, size cap on URLSession responses
- Low priority — HTTPS-only via ATS already limits exposure

## Relative Image Support in File Viewers
- `MarkdownFileView` and `NativeFullScreenMarkdownBody` create `Configuration` without `workspaceID`/`serverBaseURL`
- Absolute URLs work, but relative workspace paths won't resolve
- Need to thread workspace context through to these viewers

## Inline Mermaid — Future Polish
- Consider inline pinch-to-zoom (removed for gesture conflict simplicity)
- Could add back with a UIControl-based approach instead of UIScrollView
- Low priority since fullscreen viewer provides zoom
