{
  "id": "fca8f6b6",
  "title": "Optimistic concurrency — expectedVersion on session metadata",
  "tags": [
    "pi-remote",
    "protocol",
    "multi-device",
    "architecture"
  ],
  "status": "open",
  "created_at": "2026-02-07T06:43:51.589Z"
}

## Context
From Happy architecture review (`ios/HAPPY_COMPARISON.md`). Not urgent for v1 single-device, but prevents subtle bugs when macOS client is added.

## Problem
Pi Remote currently uses last-write-wins for all session state. When we add a macOS client sharing the same session, two clients could simultaneously update session metadata (name, model, status) and silently overwrite each other's changes.

## Design
Add optimistic concurrency control to session metadata updates:

- Add `metadataVersion: number` to Session type (starts at 1, increments on each update)
- Mutation endpoints (`POST /sessions/:id/metadata`, future model/name changes) require `expectedVersion`
- Server checks: if `expectedVersion !== current.metadataVersion`, return 409 with current state
- Client retries with fresh state (read-modify-write loop)
- For non-conflicting fields, server can merge (e.g., cost update doesn't conflict with name change)

### Scope
Only metadata that clients can mutate:
- Session name
- Session model (future: model switching mid-session)
- Permission policy preferences

NOT needed for:
- Token counts, cost (server-only writes, no conflict possible)
- Session status (server-authoritative state machine)
- Message content (append-only, no conflicts)

### Wire Format
```json
// Request
{ "name": "new name", "expectedVersion": 3 }

// Success response
{ "ok": true, "version": 4, "session": { ... } }

// Conflict response (409)
{ "error": "version_mismatch", "currentVersion": 5, "session": { ... } }
```

## Files
- `pi-remote/src/types.ts` — add `metadataVersion` to Session
- `pi-remote/src/storage.ts` — version check on save
- `pi-remote/src/server.ts` — 409 response on mismatch
- `ios/PiRemote/Core/Models/Session.swift` — decode metadataVersion
- `ios/PiRemote/Core/Networking/APIClient.swift` — send expectedVersion on updates

## Inspired By
Happy's `expectedVersion` on all versioned fields (metadata, agentState, daemonState, artifact header/body, access keys, KV). Returns `version-mismatch` with current data for client-side merge.

## Priority
Low — only matters for multi-device (macOS client). Fine to defer until then.
