# Chat Timeline Renderer — Active Path Checklist

_Last updated: 2026-02-12_

Source of truth for routing: `ios/PiRemote/Features/Chat/ChatTimelineCollectionView.swift`
(`Coordinator.configureDataSource` switch over `ChatItem`)

## Legend

- **UIKit native** = `UIContentConfiguration` custom row
- **SwiftUI hosted** = `UIHostingConfiguration { ... }`

## Row-by-row active path

| UI element / row | Active path | Renderer entry point | Notes |
|---|---|---|---|
| User message (text-only) | UIKit native | `UserTimelineRowConfiguration` | Unified user row |
| User message (with images) | UIKit native | `UserTimelineRowConfiguration` | Async base64 decode, thumbnail strip, tap → `NativeZoomableImageViewController` |
| Assistant message (plain text) | UIKit native | `AssistantTimelineRowConfiguration` → `AssistantMarkdownContentView` | Unified renderer |
| Assistant message (rich markdown: headings, lists, code blocks, tables, inline) | UIKit native | `AssistantTimelineRowConfiguration` → `AssistantMarkdownContentView` | Same renderer — parses via cmark, renders FlatSegment natively |
| Thinking (collapsed) | UIKit native | `ThinkingTimelineRowConfiguration` | Compact/native path |
| Thinking (expanded) | UIKit native | `ThinkingTimelineRowConfiguration` | Native expanded viewport (200pt cap, shrink-to-fit) + selectable text |
| Tool: bash | UIKit native | `ToolTimelineRowConfiguration` | Keep plain terminal-like rendering |
| Tool: read (collapsed) | UIKit native | `ToolTimelineRowConfiguration` | Native shell for compact list perf (includes namespaced forms like `functions.read`) |
| Tool: read (expanded) | UIKit native | `ToolTimelineRowConfiguration` | Native expanded viewport; image reads use media-aware hosted rendering so inline previews render instead of raw base64 text |
| Tool: write (collapsed) | UIKit native | `ToolTimelineRowConfiguration` | Native shell for compact list perf (includes namespaced forms like `tools/write`) |
| Tool: write (expanded) | UIKit native | `ToolTimelineRowConfiguration` | Native expanded text viewport (no renderer swap on toggle) |
| Tool: edit (collapsed) | UIKit native | `ToolTimelineRowConfiguration` | Native shell shows diff stats / modified fallback in trailing slot |
| Tool: edit (expanded) | UIKit native | `ToolTimelineRowConfiguration` | Native unified-diff viewport with single line-number gutter, syntax-aware context rows, adaptive taller height cap, and horizontal pan for long lines (no renderer swap) |
| Tool: todo (collapsed) | UIKit native | `ToolTimelineRowConfiguration` | Native shell for compact list perf |
| Tool: todo (expanded) | UIKit native | `ToolTimelineRowConfiguration` | Native expanded text viewport (no renderer swap on toggle) |
| Tool: non-bash with inline media URI | UIKit native | `ToolTimelineRowConfiguration` | Native row stays active; inline-media detection surfaces warning affordance instead of attempting inline media rendering in tool output |
| Tool: other non-parity-critical | UIKit native | `ToolTimelineRowConfiguration` | Native default |
| Permission (historical pending) | UIKit native | `PermissionTimelineRowConfiguration` | Renders as resolved marker (`expired`) |
| Permission resolved | UIKit native | `PermissionTimelineRowConfiguration` | Native status row |
| System event | UIKit native | `SystemTimelineRowConfiguration` | Native status row |
| Error row | UIKit native | `ErrorTimelineRowConfiguration` | Native status row |
| Audio clip row | UIKit native | `AudioClipTimelineRowConfiguration` | Native waveform + playback control |
| Load more row | UIKit native | `LoadMoreTimelineRowConfiguration` | Native button row |
| Working indicator row | UIKit native | `WorkingIndicatorTimelineRowConfiguration` | Native π + animated dots |

## Migration todo (non-parity-risk)

- [x] Audio clip row (`.audioClip`) -> native
- [x] Load more row -> native
- [x] Working indicator row -> native
- [x] Thinking expanded row -> native

## SwiftUI status

`UIHostingConfiguration` is only used inside expanded read rows for
media-aware rendering (`read` image outputs with inline previews).

All other row types render via native `UIContentConfiguration` with no
SwiftUI bridge in the cell hot path.

Parity gaps currently surfaced via native warning/failsafe rows:

- media-rich non-bash/non-read tool outputs (inline media presentation parity pending)
