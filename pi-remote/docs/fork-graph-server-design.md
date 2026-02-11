# Pi Remote — Fork Graph Server Design (pi-native)

Date: 2026-02-11
Owner: pi-remote server
Related:
- `IMPLEMENTATION.md` Step 10 (`TODO-19cb0451`)
- `ios/docs/fork-experience-spike.md`

## Goal

Provide a server-side fork graph that is:

1. **pi-native** (derived from pi's own session lineage)
2. **runtime-agnostic** (host/container parity)
3. **cheap to compute** (header-level parsing, cached)
4. **stable for clients** (single API shape for iOS/macOS)

---

## Key decision

Use **pi JSONL session headers** as the source of truth for branch lineage.

From pi internals, each session file starts with a `type: "session"` record containing:

- `id` (pi session UUID)
- `timestamp`
- `parentSession?` (path to parent session file for forks)

Example child header:

```json
{
  "type": "session",
  "id": "9e93be85-fa4b-4b16-9695-97ed41a619cf",
  "timestamp": "2026-02-11T19:59:36.786Z",
  "cwd": "/Users/chenda/workspace/pios",
  "parentSession": "/Users/chenda/.pi/agent/sessions/.../2026-02-11T19-59-35-161Z_79a0a8db-8a00-4354-9c45-d1a05338c5ba.jsonl"
}
```

This is canonical and already maintained by pi; server should project it, not reinterpret it.

---

## Non-goals

- Do not invent fork relationships from rendered trace event IDs.
- Do not require full JSONL parse for graph construction.
- Do not make graph availability depend on active processes.

---

## Data model (server projection)

```ts
interface ForkGraphNode {
  id: string; // piSessionId (UUID)
  sessionFile: string;
  createdAt: number; // ms epoch from header timestamp
  parentId?: string; // piSessionId
  parentSessionFile?: string;

  // projection metadata
  workspaceId: string;
  attachedSessionIds: string[]; // pi-remote sessions that reference this file/id
  activeSessionIds: string[];   // attached + currently active
  label?: string;               // optional, derived later from session name/first user msg
}

interface ForkGraph {
  workspaceId: string;
  generatedAt: number;
  nodes: ForkGraphNode[];
  roots: string[]; // node ids
  current?: {
    sessionId: string;   // pi-remote session id
    nodeId?: string;     // current piSessionId for that session
  };
}
```

Notes:
- Node identity is `piSessionId`, not pi-remote `Session.id`.
- Multiple pi-remote sessions may point to one node over time.

---

## Build algorithm

## Inputs

For one workspace:
1. all persisted pi-remote sessions in that workspace
2. each session's `piSessionFile`, `piSessionFiles[]`, `piSessionId`

## Candidate file set

Start with union of known files from session metadata.

Then recursively include parents:
- read first JSON line of each file
- if `parentSession` exists and file exists, enqueue it
- if parent path missing, fallback by UUID parsed from parent path filename suffix

## Header parsing strategy

Read only first line (`type: "session"`) for lineage graph.

Avoid full trace parse unless explicitly requested by trace endpoint.

## Attachments

For each node:
- `attachedSessionIds`: all sessions where `piSessionFile`/`piSessionFiles` include node file or `piSessionId` matches
- `activeSessionIds`: subset currently active in `SessionManager`

## Root detection

Root = node with no `parentId` OR parent missing from node set.

---

## Cache design

Add a workspace-scoped in-memory cache:

```ts
Map<workspaceId, {
  graph: ForkGraph,
  fileMeta: Map<sessionFile, { mtimeMs: number; size: number }>
}>
```

Invalidation triggers:
1. session metadata mutation (`saveSession` where piSession fields changed)
2. successful `fork` RPC result
3. session start/stop (active attachment changes)
4. stale TTL (e.g. 30s) as safety net

Header reparse only when file `(mtime,size)` changed.

---

## API design

Primary endpoint:

`GET /workspaces/:wid/fork-graph`

Optional query:
- `sessionId=<sid>` → populate `current` anchor
- `includePaths=true|false` (default false for privacy; true for debug clients)

Response:

```json
{
  "workspaceId": "w1",
  "generatedAt": 1770841000000,
  "nodes": [
    {
      "id": "79a0a8db-8a00-4354-9c45-d1a05338c5ba",
      "sessionFile": ".../2026-02-11T19-59-35-161Z_79a0a8db-....jsonl",
      "createdAt": 1770839975161,
      "attachedSessionIds": ["Sabc"],
      "activeSessionIds": [],
      "workspaceId": "w1"
    },
    {
      "id": "9e93be85-fa4b-4b16-9695-97ed41a619cf",
      "parentId": "79a0a8db-8a00-4354-9c45-d1a05338c5ba",
      "createdAt": 1770839976786,
      "attachedSessionIds": ["Sabc"],
      "activeSessionIds": ["Sabc"],
      "workspaceId": "w1"
    }
  ],
  "roots": ["79a0a8db-8a00-4354-9c45-d1a05338c5ba"],
  "current": { "sessionId": "Sabc", "nodeId": "9e93be85-fa4b-4b16-9695-97ed41a619cf" }
}
```

---

## Session manager hook changes

On successful `fork` RPC passthrough:

1. call `get_state` immediately
2. persist new `piSessionFile`, `piSessionId`, `piSessionFiles`
3. emit/broadcast updated `state`
4. notify fork-graph cache invalidator for workspace

This keeps graph and active session state coherent.

---

## Error handling

1. **Missing parent file**
   - keep child node
   - `parentId` omitted
   - optional debug warning in server logs

2. **Malformed/empty header**
   - skip file for graph, do not fail request

3. **Large history**
   - cap nodes per response (e.g. 2k) with deterministic pruning by recency if needed

4. **No lineage data**
   - return empty graph (`nodes: []`), 200 status

---

## Security and privacy

- Enforce existing workspace auth boundary.
- Default response should avoid absolute filesystem paths unless `includePaths=true` (or debug profile).
- Never expose unrelated workspace nodes.

---

## Why this is the right boundary

- pi already defines lineage (`parentSession`); server should project, not duplicate logic.
- Works for current RPC-fork-in-place model and future server-side sibling-session forks.
- Gives clients a stable graph API independent of internal path layout changes.

---

## Implementation phases

### Phase 1 (minimal, high value)

- Add graph builder from known session metadata + header recursion
- Add `GET /workspaces/:wid/fork-graph`
- Add immediate post-fork `get_state` sync + cache invalidation

### Phase 2 (robustness)

- file `(mtime,size)` cache
- optional `includePaths` gate
- node labels from session names/first user message preview

### Phase 3 (future Step 10 alignment)

- When REST workspace fork lands, include explicit fork lineage metadata in session records
- keep graph API unchanged (projection remains pi-native)
