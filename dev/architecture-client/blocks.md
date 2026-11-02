# Oppi client architecture: Client blocks and shared core

Part of [Oppi client architecture](../architecture-client.md); same standard (owners, boundaries, invariants, entry points).

## Client blocks

| Block | Owns | Does not own |
| --- | --- | --- |
| `ServerConnection` | HTTPS/WSS composition, API/WS client wiring, focused and app-event stream startup, shared store updates | per-session timeline state |
| `SessionContentAccess` | iOS row content reads (attachments, session and host files, Markdown media), bounded readiness waits, origin routing | API-client installation, auth, lifecycle |
| `ChatTimelineDestinationPresenter` | building and presenting the screens a timeline destination opens | deciding which destination a tap means |
| `MarkdownResourceAccess` | one document's source identity plus deferred resource providers, carried unchanged row → renderer → reader | routing, readiness, `sourceFilePath` |
| `ToolExpandedMarkdownSurface` / `ToolExpandedHostedSurface` | a tool row's expanded Markdown viewport / hosted media and document viewport, their constraints and teardown | header, gestures, which surface is active, outer scroll |
| `DocumentFamily` (`Core/Views/DocumentFamily.swift`) | CSV/TSV and GeoJSON/TopoJSON formats: classification, traits, Source toggle, export, view factory | parsing (`OppiCore`), rendering views, rendered fences |
| `APIClient` | authenticated HTTP and decoding | UI or store policy |
| `WebSocketClient` | focused-session transport, reconnect policy | protocol side effects |
| `AppEventStreamClient` + coordinator | app-event stream | focused timeline replay |
| `SessionStreamCoordinator` | per-session stream continuations, queue sync, focused transport lifecycle | rendering |
| `SessionStreamCatchUpTracker` | durable event sequence tracking for repair | transport, telemetry |
| `FocusedSessionConnectionPolicy` | whether a focused stream may open for a `SessionStatus` | opening, history, resume |
| `FocusedSessionStopTurnPolicy` | stop requested/confirmed/failed effects, 10 s reconcile delay | reducer mutation, HTTP reconcile |
| `ExtensionSurfaceReducer` | protocol-derived extension-surface snapshot and placement | platform paint |
| `MessageSender` | command request ids, acks, retries, result waiters | list rendering |
| `ChatSessionManager` | transport-neutral per-session runtime behind three ports | transport composition, app-event routing |
| `SessionStore` | session cache, list projection, per-server partitions, seen ledger | workspace catalog |
| `WorkspaceStore` | workspace catalog and summaries, per-server freshness | session lifecycle, server-global extensions |
| `ServerResourceStore` | per-server Skill and Extension snapshots, cached-first load, toggle rollback | workspace overrides, UI grouping |
| `AskRequestStore` + extension UI state | pending asks, dialogs, status/widget/surface state | server permission policy |
| `TimelineReducer` + `DeltaCoalescer` | timeline model and delta coalescing | UIKit, network |

## Shared Apple client core

`clients/apple/OppiCore/**` compiles into both iOS and macOS and holds protocol DTOs, `ChatSessionManager` and its ports, reducers, stream and policy state, stores, formatting, and the CommonMark parser (`OppiCore/Formatting`). It stays platform-neutral; UI and device work belongs in `Oppi/**` or `OppiMac/**`.

## Tool inspection

- `ToolContentDescriptorBuilder` owns the `ToolInspection` envelope (input fields with roles, recorded calls, output leaves, raw output, completeness); `ToolCallDocumentBuilder` composes generic Input/Calls/Output; `OrderedJSON` keeps key order and number lexemes under byte/depth/node limits.
- Producer facts select native inspection, never tool names. A known `outputPresentation.kind` gates terminal, file, and edit-diff specialization; terminal leaves carry output only. Code versus arguments comes from the code role. File painters use the descriptor's resolved type without re-sniffing.
- `ToolFileInspection` is the single source of file roles, types, provenance, and diff statistics: args-derived diffs say Requested, write content carries no label, result patches and numbered Pi diffs take precedence.
- Nested calls (`parentToolCallId`): `LiveNestedToolCalls` folds children into the parent's Calls and child output creates no row; the canonical parent result replaces the live projection and completed parents win over replayed child starts; dropped calls keep the live projection incomplete. `NestedToolCalls.summary` is the one summary.
- `outputPresentation.kind: "interactive"` marks settlement; automatic expansion skips it. Voice settings change only on the declared `settingEffect: "voiceReplyMode"` with a valid successful result; result details alone cannot change preferences.
- `ToolDisplay` is a producer fact in `ToolArgsStore`; its humanizer acts on `display.title` only. The MCP fallback resolver is server-side (`server/src/mobile-renderer-display.ts`); Apple clients do not parse MCP names. Outline snapshots never carry written file contents.
- `OppiCore/Formatting/BuiltInToolFacts.swift` is the sole client tool-identity exception: it supplies registry facts only when both presentations are absent and the exact name is `bash`, `read`, `write`, `edit`, or `ask` (no case or prefix normalization); any producer fact suppresses it and synthetic facts are never stored.
- Only Mac still interprets tool names (`OppiMac/Views/MacSessionTimelineViews.swift`, `OppiMac/Formatting/MacLegacyToolCallFormatting.swift`), pending its inspection slice.

## Mac adapter path

Share semantics; paint and adapt per platform. Do not merge the Unix-socket and HTTPS transports, or the Mac and iOS renderers, to reduce file count.

| Layer | Owner |
| --- | --- |
| Protocol DTOs, `ChatSessionManager` ports, reducers, focused-session policy, extension-surface state | `OppiCore` |
| Paired HTTPS/WSS, device auth, UIKit timeline, iOS navigation | `clients/apple/Oppi/**` |
| Owner Unix-socket HTTP/WebSocket, attach/LaunchAgent/spawn, TCC, AppKit/SwiftUI paint | `clients/apple/OppiMac/**` |

- The Mac app sends the owner `sk_` token only on the Unix socket; unauthenticated `GET /health` may use localhost HTTPS; remote WSS never carries `sk_`.
- `MacServerLifecycle.startupPlan` attaches when `/health` succeeds, else waits for an installed LaunchAgent, else spawns `oppi serve`.
- `MacChatSessionRuntimeAdapter` implements the same three `ChatSessionManager` ports over `MacSessionTraceStore` and the owner socket.
