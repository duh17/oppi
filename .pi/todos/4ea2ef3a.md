{
  "id": "4ea2ef3a",
  "title": "CLOSED: Persistent vs ephemeral event split — merged into TODO-fb28452c",
  "tags": [
    "pi-remote",
    "protocol",
    "architecture"
  ],
  "status": "done",
  "created_at": "2026-02-07T06:43:36.244Z"
}

## Context
From Happy architecture review (`ios/HAPPY_COMPARISON.md`). We partially do this but haven't formalized it.

## Problem
All server→client WebSocket events are treated the same. Some events are durable state changes (message added, session status changed, permission resolved) that must survive reconnect. Others are transient signals (thinking indicator, delta text fragments, typing presence) that are meaningless after the moment passes. Mixing them makes reconnect harder and event buffering wasteful.

## Design
Tag each event type as `persistent` or `ephemeral`:

### Persistent (sequenced, buffered, recoverable)
- `state` (session status/metadata changes)
- `message_start` / `message_end`
- `tool_call` / `tool_result`
- `permission_request` / `permission_resolved`
- `agent_start` / `agent_end`
- `error`

### Ephemeral (not sequenced, not buffered, fire-and-forget)
- `delta` (text streaming fragments)
- `thinking` (thinking indicator toggle)
- `typing` (user typing indicator, future)
- `heartbeat` / `pong`

### Implementation
- Persistent events get a `seq` number (see sequenced updates TODO)
- Ephemeral events have no seq, are not stored in the event buffer
- Server event buffer only stores persistent events for catch-up
- iOS client: persistent events update durable state, ephemeral events update transient UI only
- On reconnect: replay persistent events from last seq, ephemeral state resets to defaults

## Files
- `pi-remote/src/types.ts` — add `durability: 'persistent' | 'ephemeral'` classification
- `pi-remote/src/sessions.ts` — only buffer persistent events, only assign seq to persistent
- `ios/PiRemote/Core/Runtime/TimelineReducer.swift` — classify incoming events
- `ios/PiRemote/Core/Runtime/DeltaCoalescer.swift` — already ephemeral, formalize

## Inspired By
Happy's `update` (persistent, sequenced) vs `ephemeral` (transient presence/usage) event types on Socket.IO.

## Priority
Medium — depends on sequenced updates TODO, but the classification can be done independently.
