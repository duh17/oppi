# Oppi client architecture: Client blocks and shared core

Part of [Oppi client architecture](../architecture-client.md).

## Client blocks

| Block | Owns | Does not own |
| --- | --- | --- |
| `ServerConnection` | HTTPS/WSS composition, API/WS client wiring, focused and app-event stream startup, shared store updates | per-session timeline state |
| `ChatTimelineDestinationPresenter` | building and presenting the screens a timeline destination opens | deciding which destination a tap means |
| `MarkdownResourceAccess` | one document's source identity plus deferred resource providers, carried unchanged row → renderer → reader | routing, readiness, `sourceFilePath` |
| `ToolExpandedMarkdownSurface` / `ToolExpandedHostedSurface` | a tool row's expanded Markdown viewport / hosted media and document viewport, their constraints and teardown | header, gestures, which surface is active, outer scroll |
| `APIClient` | authenticated HTTP and decoding | UI or store policy |
| `WebSocketClient` | focused-session transport, reconnect policy | protocol side effects |
| `SessionRouteScope` | workspace or `/control-sessions/:sessionId` paths, both feeding one `ChatSessionManager` | transport |
| `AppEventStreamClient` + coordinator | app-event stream (lists, attention) | focused timeline replay |
| `SessionStreamCoordinator` | per-session stream continuations, queue sync, focused transport lifecycle | rendering |
| `SessionStreamCatchUpTracker` | durable event sequence tracking for repair | transport, telemetry |
| `FocusedSessionConnectionPolicy` | whether a focused stream may open for a `SessionStatus` | opening, history, resume |
| `FocusedSessionStopTurnPolicy` | stop requested/confirmed/failed effects, 10 s reconcile delay | reducer mutation, HTTP reconcile |
| `MessageSender` | command request ids, acks, retries, result waiters | list rendering |
| `ChatSessionManager` | transport-neutral per-session runtime behind three ports | transport composition, app-event routing, live-stream auth, dictation |
| `SessionStore` | session cache, list projection, per-server partitions, seen ledger | workspace catalog |
| `WorkspaceStore` | workspace catalog and summaries, compact Git summary, per-server freshness | session lifecycle, server-global extensions |
| `ServerResourceStore` | per-server Skill and Extension snapshots, cached-first load, toggle rollback | workspace overrides, UI grouping |
| `TimelineReducer` + `DeltaCoalescer` | timeline model and delta coalescing | UIKit, network |

- A main-checkout `workspace_git_changed` repairs `WorkspaceStore`'s Git summary over HTTP, keeping the last trustworthy value on failure.
- `ServerConnection+StoreUpdates.swift` (session, workspace summary, screen-awake, Live Activity) and `+MessageRouter.swift` (UI, queue, extension, command-result effects) apply a live event to shared stores exactly once; `ChatSessionManager` then routes timeline events to its reducer. When a non-focused session has its own live consumer, cross-session handling defers the message types that consumer owns.

## Focused session

`ChatSessionManager` (`OppiCore/Runtime/`) owns the session's reducer, coalescer, and tool-call correlator, sequences cache → paged trace → catch-up, and imports no app service or UI framework. `IOSChatSessionRuntimeAdapter` classifies iOS trace-page 404/405/409 fallback.

- First connect seeds sequence tracking; reconnect uses catch-up. A ring miss (`live: true`, `catchUpComplete: false`) or no ring (`live: false`) repairs from trace history; `live: false` does not persist the response cursor. A missing session is 404.
- A send while the chat reads busy goes as `prompt` with `streamingBehavior`, never bare `steer`/`follow_up`: the turn may have ended by the time the server reads it.
- Loaded history is one contiguous range ending at the live tail (`TimelineReducer.prependTracePage` grows the head). A jump to an unloaded entry pages back (`targetEvents=1000`, at most 20 pages), never loads a detached page, and does not scroll if it cannot load.
- **Focus claims** (`FocusedSessionStore`): each mounted runtime holds a claim and releases only its own; a newer claim supersedes older ones, and a superseded runtime never binds, reconnects, or releases the stream. When the current claim goes while an older runtime for the same session is mounted (an iPad layout swap), `ServerConnection` hands focus back via `focusClaimRegained()`.
- A still-stopped session stays history-only ([cross-system invariants](../architecture.md#cross-system-invariants)); `FocusedSessionConnectionPolicy` refreshes a locally stopped session's history first.
- Durable sessions take their timeline from the conversation stream: [Apple client](../architecture-server/durable-conversation-stream.md#apple-client).

## Extension UI

Render protocol metadata only ([boundary rules](../architecture-client.md#client-boundary-rules-current-code)). `AskRequestStore` holds asks, `ExtensionDialogQueue` dialogs, and `ExtensionSurfaceState` (`OppiCore/Runtime/`) the per-session surface snapshot, reducer, and placement (`extensionSurfaceBySession` on iOS, `MacSessionTraceStore.extensionSurface` on Mac).

- `ServerConnection+Ask.swift` answers over the focused stream, or over HTTP when the focused WebSocket is not bound to the target session.
- `ExtensionNativeBlockViews.swift` keeps block views by id so a replacement snapshot preserves view state; `ExtensionNativeBlockPresentation.swift` holds the framework-free rules.
- `ElapsedLabelTicker` (`ExtensionSurfaceBlockNodeViews.swift`) is the one 1 Hz clock for every surface `elapsed` label. A label attaches while it is in a window, and the timer exists only while one is attached; never give a label its own timer.

## Shared Apple client core

`clients/apple/OppiCore/**` compiles into iOS and macOS: protocol DTOs, `ChatSessionManager` and its ports, reducers, stream and policy state, stores, formatting, and the CommonMark parser (`OppiCore/Formatting`). UI and device work belongs in `Oppi/**` or `OppiMac/**`.

## Tool inspection

Server side (producer facts, registry, full output): [Tool inspection](../architecture-server/tool-inspection.md).

- `ToolContentDescriptorBuilder` owns the `ToolInspection` envelope (input fields with roles, recorded calls, output leaves, raw output, completeness); `ToolCallDocumentBuilder` composes generic Input/Calls/Output; `OrderedJSON` keeps key order and number lexemes under byte/depth/node limits.
- Producer facts select native inspection, never tool names. A known `outputPresentation.kind` gates terminal, file, and edit-diff specialization; terminal leaves carry output only; code versus arguments comes from the code role; file painters use the descriptor's resolved type without re-sniffing.
- `ToolFileInspection` is the single source of file roles, types, provenance, and diff statistics: args-derived diffs say Requested, write content carries no label, result patches and numbered Pi diffs take precedence.
- Nested calls (`parentToolCallId`): `LiveNestedToolCalls` folds children into the parent's Calls and child output creates no row; the canonical parent result replaces the live projection, completed parents win over replayed child starts, and dropped calls keep it incomplete. `NestedToolCalls.summary` is the one summary.
- `outputPresentation.kind: "interactive"` marks settlement and automatic expansion skips it. Voice settings change only on the declared `settingEffect: "voiceReplyMode"` with a valid successful result.
- `ToolDisplay` is a producer fact in `ToolArgsStore`; its humanizer acts on `display.title` only. Apple clients do not parse MCP names (the fallback resolver is `server/src/mobile-renderer-display.ts`).
- `OppiCore/Formatting/BuiltInToolFacts.swift` is the sole client tool-identity exception: it supplies registry facts only when both presentations are absent and the exact name is `bash`, `read`, `write`, `edit`, or `ask` (no case or prefix normalization), never availability or setting authority; any producer fact suppresses it and synthetic facts are never stored.
- Only Mac still interprets tool names (`OppiMac/Views/MacSessionTimelineViews.swift`, `OppiMac/Formatting/MacLegacyToolCallFormatting.swift`), pending its inspection work.

## Mac adapter path

Share semantics; paint and adapt per platform. Do not merge the Unix-socket and HTTPS transports, or the Mac and iOS renderers, to reduce file count.

| Layer | Owner |
| --- | --- |
| Protocol DTOs, `ChatSessionManager` ports, reducers, focused-session policy, extension-surface state | `OppiCore` |
| Paired HTTPS/WSS, device auth, UIKit timeline, iOS navigation | `clients/apple/Oppi/**` |
| Owner Unix-socket HTTP/WebSocket, attach/LaunchAgent/spawn, TCC, AppKit/SwiftUI paint | `clients/apple/OppiMac/**` |

- `MacServerLifecycle.startupPlan` attaches when `/health` succeeds, else waits for an installed LaunchAgent, else spawns `oppi serve`.
- `MacChatSessionRuntimeAdapter` implements the same three `ChatSessionManager` ports over `MacSessionTraceStore` and the owner socket.
