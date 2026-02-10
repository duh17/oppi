{
  "id": "31efdce1",
  "title": "Phase 1: API migration — workspace-scoped endpoints + legacy compat",
  "tags": [
    "pi-remote",
    "server",
    "workspace",
    "api",
    "phase-1"
  ],
  "status": "done",
  "created_at": "2026-02-08T01:25:36.848Z"
}

## Context

IMPLEMENTATION.md Phase 1. Add workspace-scoped session APIs while keeping
legacy routes working for the current iOS app.

Tracker: TODO-748506dc
Depends on: Phase 0 (workspace runtime)

## Deliverables

1. **Workspace session APIs:**
   - `GET /workspaces/:wid/sessions`
   - `POST /workspaces/:wid/sessions`
   - `POST /workspaces/:wid/sessions/:sid/resume`
   - `POST /workspaces/:wid/sessions/:sid/stop`

2. **Legacy compatibility routes (keep during transition):**
   - `GET/POST /sessions`
   - `GET /sessions/:id`
   - `WS /sessions/:id/stream`
   - Legacy session creation maps to default workspace

3. **Session metadata source-of-truth:** storage remains authoritative.
   Background reconciliation job for status drift.

4. **Protocol versioning signal:** `X-PiRemote-Protocol` header or WS
   handshake field.

## Acceptance Criteria (from IMPLEMENTATION.md)

- New iOS can use workspace-scoped APIs
- Existing iOS continues to work unchanged
- Server logs deprecation warnings for legacy routes (no breakage)
- Metadata remains consistent after process crashes/restarts

## Validation

- API contract tests for both legacy + new routes
- Backward compatibility test matrix documented in PR

## Files

- `pi-remote/src/server.ts` — new routes + deprecation warnings
- `pi-remote/src/types.ts` — protocol version field
- `pi-remote/tests/api-compat.test.ts` — NEW

---

## Implementation Order: Step 8

Follows directly from Step 7 (workspace runtime). ~1-2 days.

## Progress

- 2026-02-09: Added workspace-scoped session routes: `GET/POST /workspaces/:wid/sessions`, `POST .../stop`, `POST .../resume`, `GET .../tool-output/:tid`, `GET .../files`, `GET/DELETE .../sessions/:sid`, `WS .../stream`.
- 2026-02-09: Added `handleListWorkspaceSessions`, `handleCreateWorkspaceSession`, `handleResumeWorkspaceSession` handlers. Existing handlers (`handleStopSession`, `handleGetToolOutput`, `handleGetSessionFile`, `handleGetSession`, `handleDeleteSession`) reused by both v1 and v2 routes.
- 2026-02-09: Legacy `/sessions*` routes kept with deprecation headers (`Deprecation: true`, `Sunset: 2026-06-01`, `Link` to successor). Server logs deprecation warnings.
- 2026-02-09: Protocol version signal: `X-PiRemote-Protocol: 2` header on all responses. Health endpoint returns `{ ok: true, protocol: 2 }`.
- 2026-02-09: WebSocket upgrade handles both `/workspaces/:wid/sessions/:sid/stream` (v2) and `/sessions/:sid/stream` (v1 with deprecation log).
- 2026-02-09: Added `tests/api-routes.test.ts` (18 tests): v2 route matching, v1 compat matching, route priority (workspace paths don't false-match legacy patterns).
- 2026-02-09: **Phase 1 complete.** 16 test files, 188 tests passing.
