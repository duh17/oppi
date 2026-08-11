# Protocol Snapshots

Canonical JSON fixtures and transport notes for the Oppi client-server protocol and Pi SDK events.

## Files

| File                      | Description                                                                | Source of truth                                                                          |
| ------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `server-messages.json`    | Canonical focused-stream `ServerMessage` shapes the iOS client must handle | Built by `server/tests/protocol-fixtures.ts`; updated only by the explicit server script |
| `app-event-messages.json` | Canonical global app-stream `AppEventMessage` shapes                       | Built by `server/tests/protocol-fixtures.ts`; updated only by the explicit server script |
| `pi-events.json`          | All pi SDK `AgentSessionEvent` shapes                                      | Hand-maintained reference (used to test `translatePiEvent` in `session-protocol.ts`)     |

## How they're used

- **`server-messages.json`** is built in memory from typed server examples and compared byte-for-byte with the committed fixture by ordinary tests. The iOS app tests its focused-stream decoder against every committed example to ensure both sides agree on the wire format.
- **`app-event-messages.json`** is built in memory and compared byte-for-byte by ordinary tests. The app stream uses these fixtures for row, attention, extension UI, and workspace invalidation events.
- Malformed and future compatibility examples stay separate from the typed canonical server-message set; they exercise decoder fallback without weakening compile-time discriminator coverage.
- **`pi-events.json`** documents the upstream Pi SDK event shapes that the server translates into `ServerMessage` types.

## WebSocket stream topology

Oppi uses HTTP snapshots as the authority for workspace and session-list state. Live WebSockets are split into a global app-event stream for store-level updates, focused-session streams for timeline and commands, and dedicated streams for dictation and mirror sessions.

| Endpoint                                              | Direction                             | Server owner            | Client owner                                           | Use case                                                                                                              |
| ----------------------------------------------------- | ------------------------------------- | ----------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `/sessions/recent` and workspace session routes       | HTTP GET                              | session routes          | `APIClient` / `SessionStore`                           | Authoritative workspace/session-list snapshots.                                                                       |
| `/workspaces/:workspaceId/attention`                  | HTTP GET                              | session routes          | `APIClient` / attention stores                         | Authoritative pending ask snapshots for the visible workspace.                                                        |
| `/app/events/stream`                                  | Server-to-client WebSocket JSON       | `AppEventStreamMux`     | `AppEventStreamClient` via `AppEventStreamCoordinator` | Global row, attention, extension UI, and workspace invalidation events. Reconnect catch-up comes from HTTP snapshots. |
| `/workspaces/:workspaceId/sessions/:sessionId/stream` | Bidirectional WebSocket JSON          | `BoundSessionStreamMux` | `WebSocketClient` via `SessionStreamCoordinator`       | Focused session timeline and commands. The URL binds the session; session commands are sent directly on this stream.  |
| `/control-sessions/:sessionId/stream`                 | Bidirectional WebSocket JSON          | `BoundSessionStreamMux` | `WebSocketClient` via `SessionStreamCoordinator`       | Focused Oppi Control timeline and commands, scope-bound by explicit control metadata.                                 |
| `/dictation/stream`                                   | Bidirectional WebSocket JSON + binary | `DictationStreamMux`    | `DictationStreamClient`                                | Server dictation control messages and PCM audio frames.                                                               |
| `/mirror/v1/bridge`                                   | Bidirectional WebSocket JSON          | `PiTuiMirrorRuntime`    | Oppi Mirror pi extension                               | Terminal-owned session registration, takeover confirmation, commands, queue sync, and extension UI proxying.          |

`stream_connected` remains the first message on the focused-session WebSocket stream. Its `serverDictationAvailable` field means the server has configured a dictation/STT backend for the dedicated session audio stream. After `dictation_start`, the session audio stream emits dictation protocol frames. If server dictation is unavailable, it emits an immediate `dictation_error`. Session-scoped frames carry `sessionId`; split session streams add it server-side from the URL so the client can route every stream-frame shape through the same decoder.

The authenticated `/control-sessions` HTTP route family mirrors focused-session detail, trace page and outline, events, commands, stop, resume, delete, tool-output, and attachment operations. A session belongs to this scope only if it has no `workspaceId` and carries explicit `control` metadata with `domain`, `intent`, and optional target identity. A missing workspace alone never declares control scope.

## Updating

Ordinary protocol tests never write tracked JSON. They build the canonical examples in memory and fail when the committed bytes differ. To deliberately regenerate both fixtures, run:

```bash
cd server
npm run protocol:fixtures:update
```

Then rerun the focused server protocol tests and verify that only an intended fixture change is present. Apple protocol tests decode every committed `server-messages.json` and `app-event-messages.json` example; named malformed/future compatibility cases remain covered without a second discriminator inventory.

For `pi-events.json`, update manually when the pi SDK adds new event types.
