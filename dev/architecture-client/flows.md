# Oppi client architecture: Transport and UI flows

Part of [Oppi client architecture](../architecture-client.md); same standard (owners, boundaries, invariants, entry points).

## Transport lanes

- **Route selection:** the client builds verified LAN HTTPS and paired HTTPS candidates, constructs the final authenticated `APIClient` per candidate, and probes `GET /server/info` under one bootstrap deadline. A route with current health evidence stays installed across foreground and network changes. Availability failures may try another candidate; unknown or revoked credentials fail closed; TLS identity or protocol failures stop fallback. Pairing probes before one non-replayed `/pair`. Logs never expose tokens or keys. Details: [Networking](../networking.md).
- The app-event stream (`/app/events/stream`) and the focused session stream stay separate: app events update lists and attention; the focused stream carries timeline events, commands, queue, and session UI. `SessionRouteScope` picks workspace or `/control-sessions/:sessionId` paths; both feed the same `ChatSessionManager`.

## Session lists

- `WorkspaceStore` owns the catalog and the compact Git summary; a main-checkout `workspace_git_changed` repairs that summary over HTTP and keeps the last trustworthy value on failure.
- `SessionStore.listProjectionSessions` feeds the inbox, workspace detail, and Quick Session lists. Lists never read full `SessionStore.sessions`: hot timeline updates change it without changing row data.
- View-driven refreshes target the selected server, so an unavailable inactive host cannot delay the inbox.
- Sidebar workspace counts come only from server state for live sessions; stopped sessions never count and opening a session on the device does not change them. Opening a session never reads a Pi JSONL file.
- Both lists build launch-tree threads with `SessionListEntries`, group with `SessionInboxGrouping`, and draw rows with `SessionListEntryConfiguration`. There is no thread screen or route.
- Incognito: `ChatViewController` deletes the session once `AppNavigation.routeContainsSession` no longer finds it (`IncognitoSessionEnd`). UIKit's moving flags are not used: they miss shell route swaps and count the lock cover as a removal.
- `AppNavigation` records utility → detail → file route metadata (with `serverId`) so stack/split transitions never request the wrong server.
- `WorkspaceCreationIntake` (`App/WorkspaceCreationIntake.swift`) consumes guided first-workspace requests and `oppi://workspace` payloads.
- Server Skill files read the file list from the already loaded detail (`ServerResourceStore.skillDetail`), never a catalog rebuild; an editable Skill file reads through `/files/current?origin=skill` when the server advertises `skillFileEditing`. An extension is editable only as a single user-owned file (`ServerExtensionListPresentation.editablePath`).
- **Guided control sessions** (`GuidedControlComposerController`, `GuidedControlSessionViewController`): opening, reading, and typing create nothing. Send posts one idempotent control-session creation whose request and comment snapshots are frozen for that idempotency key; retries resend those exact fields; success clears only comments byte-identical to the sent snapshot, and the composer takes a fresh key. A preflight failure keeps text and comments. Skill drafts key by opaque Skill id. Workspace Settings never shows the composer under the lock cover, and a send in flight when the lock engages opens nothing.

## Focused session flow

`ChatViewController` creates a `ChatSessionManager` (`OppiCore/Runtime/`), which owns the session's reducer, coalescer, and tool-call correlator and sequences cache → paged trace → catch-up. It depends on three ports (history/cache, focused stream, effects/state) and imports no app service or UI framework. iOS trace-page 404/405/409 fallback is classified by `IOSChatSessionRuntimeAdapter`. Live-stream auth, app events, and dictation stay outside this boundary.

- First connect seeds sequence tracking; reconnect uses catch-up. A ring miss (`live: true`, `catchUpComplete: false`) or a session with no ring (`live: false`) repairs from trace history; `live: false` does not persist the response cursor. A missing session is 404.
- A send while the chat reads busy goes as `prompt` with `streamingBehavior`, never bare `steer`/`follow_up`, because the turn may have ended by the time the server reads it. An idle send stays a plain prompt.
- Loaded history is one contiguous range ending at the live tail; `TimelineReducer.prependTracePage` grows the head. A jump to an unloaded entry pages back (`targetEvents=1000`, at most 20 pages) and never loads a detached page; a jump that cannot load does not scroll.
- **Focus claims** (`FocusedSessionStore`): each mounted runtime holds a claim and releases only its own; a newer claim supersedes older ones, and a superseded runtime never binds, reconnects, or releases the stream. When the current claim goes while an older runtime for the same session is mounted (an iPad layout swap), `ServerConnection` hands focus back via `focusClaimRegained()`.
- Stopped sessions load history without opening the focused WebSocket, because opening it can resume server-owned execution. `FocusedSessionConnectionPolicy`: a locally stopped session refreshes history first, and a still-stopped refresh stays history-only.

### Durable sessions: the conversation stream

When the server advertises `capabilities.conversationStream` and the session is `engine: durable`, the timeline comes from the [conversation stream](../architecture-server/durable-conversation-stream.md) with no flag and no fallback to events. Mac does not attach yet; stopped durable sessions are history-only.

- **Attach:** `ConversationStreamDriver` keeps the `ConversationReplica` across reconnects and resumes with `conversationId`/`afterEntryId`. A failed attach retries without a cursor once per socket; a second failure is fatal. A frame the replica cannot apply re-attaches without a cursor and drops frames until the snapshot.
- **Committed rows:** `ConversationCommittedProjection` projects only entries newer than the replica onto `TimelineReducer.applyConversationCommitted`'s incremental path (a full comparison is linear in the conversation); snapshots, `older` pages, and restated entries re-project. Each new committed user entry consumes the oldest pending optimistic prompt.
- **Live tail:** `ConversationLiveProjector` reads only `pi.live`. The frame that commits an answer also clears it from `pi.live`, applied in one main-actor turn, so there is no gap or duplicate; live rows keep their ids and `TimelineReducer.timelineItemID(for:)` maps committed ids to them.
- **Busy:** `ChatSessionManager.isBusy` is the one busy rule (`pi.live.run` from the session's own replica once seen, else session status); a child's tail never feeds it. The timeline stamps `isBusy` on each owned apply, so the frame that ends a run clears the working indicator in the same apply. The queue comes from `pi.inbox`.
- **Classic frames:** what still arrives (`notice`, `error`, `cache_miss`, `session_ended`, stop feedback, failed command results) becomes `TimelineClientRow`s via `ChatSessionManager.routeToConversationTimeline`; they survive rebuilds from the replica.
- **Child tails:** `ConversationChildIndex` finds child conversations from tool `details` (`conversationId`, `sessionId`), never tool or extension names. The manager follows children the parent waits on, others only while a drawer is expanded (`followsReturnedChildren`), and none on a server without live tails (a v1 `attach` replaces the socket's only stream). Frames route by `conversationId`; others are dropped. A refused live attach never touches the session's own stream. Tails publish at most four times a second.
- **Paging:** `older { beforeEntryId }`. While the scene is paused, frames update only the replica and the timeline resyncs on resume.

## Shared store updates

`ServerConnection+StoreUpdates.swift` applies session, workspace summary, screen-awake, and Live Activity changes; `ServerConnection+MessageRouter.swift` applies UI, queue, extension, and command-result effects; `ChatSessionManager` then routes timeline events to its reducer. A live event mutates shared stores exactly once; when a non-focused session has its own live consumer, cross-session handling defers the message types that consumer owns.

## Extension UI on Apple

Extension UI is extension-agnostic: render protocol metadata, never branch on tool, extension, status, widget, or display names.

- `OppiCore/Stores/AskRequestStore.swift`: ask cards. `ExtensionDialogQueue` (`Core/Networking/ExtensionDialogQueue.swift`): per-session dialogs. `OppiCore/Runtime/ExtensionSurfaceState.swift`: the shared snapshot, reducer, and placement, stored per session (`extensionSurfaceBySession` on iOS, `MacSessionTraceStore.extensionSurface` on Mac).
- `ServerConnection+Ask.swift` responds over the focused stream, or over HTTP when the focused WebSocket is not bound to the target session.
- `ExtensionSurfacePanel.swift` / `MacExtensionSurfacePanel.swift` paint. `ExtensionNativeBlockViews.swift` keeps block views by id so a replacement snapshot preserves view state; `OppiCore/Runtime/ExtensionNativeBlockPresentation.swift` holds the framework-free rules.
