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
  "status": "backlog",
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
