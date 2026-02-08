# Workspaces — Contract Summary

This file is a **concise contract summary**. It is not the roadmap owner.

## Source of Truth

- `README.md` — current shipped behavior and public API examples.
- `IMPLEMENTATION.md` — execution checklist + acceptance criteria.
- `WORKSPACE-CONTAINERS.md` — target architecture (`workspace = container`) and migration plan.
- `DESIGN.md` — broader design context (historical sections included).

If these docs disagree, use the precedence above.

---

## Current Implemented Workspace Model

Server type (`pi-remote/src/types.ts`):

```ts
interface Workspace {
  id: string;
  userId: string;
  name: string;
  description?: string;
  icon?: string;
  skills: string[];
  policyPreset: string;
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  defaultModel?: string;
  createdAt: number;
  updatedAt: number;
}
```

Session linkage:

```ts
interface Session {
  workspaceId?: string;
  workspaceName?: string;
}
```

---

## Current Implemented APIs

### Workspace APIs

- `GET /workspaces`
- `POST /workspaces`
- `GET /workspaces/:id`
- `PUT /workspaces/:id`
- `DELETE /workspaces/:id`

### Skill APIs

- `GET /skills`
- `POST /skills/rescan`

### Session creation

- `POST /sessions` accepts optional `workspaceId`
- If `workspaceId` is omitted, server resolves a default workspace

---

## Runtime Reality (Today)

Current runtime is still **session-scoped** at the container/process home level.
Workspace config is already used to influence session bootstrap (skills, prompt,
host mount, memory options), but container ownership is not yet workspace-scoped.

Planned evolution to workspace-owned runtime is tracked in:
- `WORKSPACE-CONTAINERS.md`
- `IMPLEMENTATION.md` (Phase 0+)

---

## iOS Status (Today)

Implemented in iOS app:
- Workspace picker when creating sessions
- Workspace management screens (list/create/edit/delete)
- Skill list integration from server
- Session UI shows workspace context

Further workspace-first runtime UX changes are tracked in `IMPLEMENTATION.md`.
