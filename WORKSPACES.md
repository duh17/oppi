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

### Workspace-scoped sessions

- `GET /workspaces/:wid/sessions`
- `POST /workspaces/:wid/sessions`
- `GET /workspaces/:wid/sessions/:sid`
- `POST /workspaces/:wid/sessions/:sid/stop`
- `POST /workspaces/:wid/sessions/:sid/resume`
- `DELETE /workspaces/:wid/sessions/:sid`

---

## Runtime Reality (Today)

Runtime is now **workspace-scoped** for container sessions:
- One container per workspace (not per session)
- Per-session process execs within the workspace container
- Per-session agent homes under workspace `sessions/<sessionId>/`
- Workspace idle timers stop containers when no active workspace sessions remain

Ongoing follow-up cleanup is tracked in:
- `WORKSPACE-CONTAINERS.md`
- `IMPLEMENTATION.md`

---

## iOS Status (Today)

Implemented in iOS app:
- Workspace picker when creating sessions
- Workspace management screens (list/create/edit/delete)
- Skill list integration from server
- Session UI shows workspace context

Further workspace-first runtime UX changes are tracked in `IMPLEMENTATION.md`.
