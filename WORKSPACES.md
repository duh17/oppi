# Workspaces — Design

## Concept

A **workspace** is a named configuration that defines what an agent session gets:
skills, permissions, context, and mounted files. When you create a session from
your phone, you pick a workspace. The sandbox configures itself accordingly.

```
Session = Workspace + Model + Conversation
```

Workspaces are the unit of agent customization. Instead of every session being
identical, you get purpose-built environments:

- **coding** — ast-grep, tmux, web-browser. Mounts ~/workspace/pios. Container policy.
- **research** — searxng, fetch, deep-research, youtube-transcript. No host mount. Container policy.
- **personal** — kypu, weather, monthly-budget-review. No host mount. Container policy.
- **quick** — searxng, fetch only. Minimal. Fast to start.

## Data Model

```typescript
interface Workspace {
  id: string;               // nanoid(8)
  userId: string;           // owner
  name: string;             // "coding", "research"
  description?: string;     // shown in workspace picker
  icon?: string;            // SF Symbol name or emoji

  // Skills — which skills to sync into the session
  skills: string[];         // ["searxng", "fetch", "ast-grep", "tmux"]

  // Permissions
  policyPreset: string;     // "container" | "restricted"

  // Context
  systemPrompt?: string;    // Additional instructions appended to base prompt
  hostMount?: string;       // Host directory to mount as /work (e.g. "~/workspace/pios")

  // Defaults
  defaultModel?: string;    // Override server default for this workspace

  // Metadata
  createdAt: number;
  updatedAt: number;
}
```

### Skill Pool

Skills are discovered from the host's `~/.pi/agent/skills/` directory. The server
scans this on startup and exposes the list via API. Each workspace references skills
by name from this pool.

```typescript
interface SkillInfo {
  name: string;             // "searxng"
  description: string;      // from SKILL.md frontmatter
  containerSafe: boolean;   // can run in Apple container
  hasScripts: boolean;      // has executable scripts (needs bin shims)
  path: string;             // host path (for sync)
}
```

Not all host skills work in containers. Some need tmux, MLX, or host-only binaries.
The server marks skills with `containerSafe` based on heuristics (presence of
`scripts/` dir, no tmux/MLX references). The iOS UI shows a warning badge on
potentially incompatible skills.

### Default Workspaces

On first user creation, seed with sensible defaults:

```typescript
const DEFAULT_WORKSPACES: Omit<Workspace, "id" | "userId" | "createdAt" | "updatedAt">[] = [
  {
    name: "general",
    description: "General-purpose agent with web search and browsing",
    icon: "terminal",
    skills: ["searxng", "fetch", "web-browser"],
    policyPreset: "container",
  },
  {
    name: "research",
    description: "Deep research with search, web, and transcription",
    icon: "magnifyingglass",
    skills: ["searxng", "fetch", "web-browser", "deep-research", "youtube-transcript"],
    policyPreset: "container",
  },
];
```

## Implementation

### Server Changes

#### 1. Skill Discovery — `src/skills.ts` (new)

Scans `~/.pi/agent/skills/` and builds the available skill pool.

```typescript
class SkillRegistry {
  private skills: Map<string, SkillInfo> = new Map();

  /** Scan host skill directories. Call on startup + on demand. */
  scan(): void

  /** Get all available skills. */
  list(): SkillInfo[]

  /** Get a single skill by name. */
  get(name: string): SkillInfo | undefined

  /** Get the host path for a skill (for syncing into containers). */
  getPath(name: string): string | undefined
}
```

#### 2. Workspace Storage — `src/storage.ts` (extend)

Add workspace CRUD alongside existing user/session storage.

```
~/.config/pi-remote/
├── config.json
├── users.json
├── workspaces/
│   └── <userId>/
│       └── <workspaceId>.json    # Workspace config
└── sessions/
    └── <userId>/
        └── <sessionId>.json
```

Methods:
- `createWorkspace(userId, data): Workspace`
- `getWorkspace(userId, workspaceId): Workspace | undefined`
- `listWorkspaces(userId): Workspace[]`
- `updateWorkspace(userId, workspaceId, updates): Workspace`
- `deleteWorkspace(userId, workspaceId): boolean`

#### 3. Workspace-Aware Sandbox — `src/sandbox.ts` (modify)

Replace hardcoded `BUILT_IN_SKILLS` with workspace-driven skill selection.

```diff
- const BUILT_IN_SKILLS = ["searxng", "fetch", "web-browser"] as const;

  initSession(
    userId: string,
    sessionId: string,
-   opts?: { userName?: string; model?: string },
+   opts?: { userName?: string; model?: string; workspace?: Workspace },
  ): { piDir: string; workDir: string } {
+   const skills = opts?.workspace?.skills ?? ["searxng", "fetch", "web-browser"];
-   const installedSkills = this.syncBuiltInSkills(agentDir);
+   const installedSkills = this.syncSkills(agentDir, skills, skillRegistry);
```

`syncSkills()` replaces `syncBuiltInSkills()` — same logic but reads skill
list from workspace instead of constant. The host path comes from `SkillRegistry`.

System prompt generation also uses workspace:
- Workspace-specific skill descriptions
- `workspace.systemPrompt` appended if present
- Workspace name included for context

#### 4. Host Mount — `src/sandbox.ts` (modify)

If `workspace.hostMount` is set, mount that directory instead of the
session-local `/work`. Resolve `~` and validate path exists.

```diff
  // In spawnPi():
+ const workMount = workspace?.hostMount
+   ? resolveHostMount(workspace.hostMount)
+   : realpath(workDir);
+
  const args = [
-   "-v", `${realpath(workDir)}:${CONTAINER_WORK}`,
+   "-v", `${workMount}:${CONTAINER_WORK}`,
```

**Safety**: `hostMount` is user-configured, not agent-controlled. The phone
app sets it. The container still provides filesystem isolation — the agent
can only see what's mounted.

#### 5. REST API — `src/server.ts` (extend)

```
GET    /workspaces               → list user's workspaces
POST   /workspaces               → create workspace
GET    /workspaces/:id           → get workspace
PUT    /workspaces/:id           → update workspace
DELETE /workspaces/:id           → delete workspace
GET    /skills                   → list available skill pool
```

Session creation gains optional `workspaceId`:

```diff
  POST /sessions
  {
    "name": "fix auth bug",
    "model": "anthropic/claude-sonnet-4-0",
+   "workspaceId": "abc123"
  }
```

If `workspaceId` is omitted, use the user's first workspace (or create a
default "general" workspace).

#### 6. Session ↔ Workspace Link — `src/types.ts`

```diff
  interface Session {
    id: string;
    userId: string;
+   workspaceId?: string;     // which workspace spawned this session
+   workspaceName?: string;   // denormalized for display
    name?: string;
    status: ...
```

### iOS Changes

#### 1. Workspace Picker on Session Creation

When tapping "New Session", show workspace grid/list before starting:

```
┌─────────────────────────┐
│  New Session             │
│                          │
│  ┌──────┐ ┌──────┐     │
│  │  >_  │ │  🔍  │     │
│  │coding│ │resrch│     │
│  └──────┘ └──────┘     │
│  ┌──────┐ ┌──────┐     │
│  │  🏃  │ │  ⚡  │     │
│  │person│ │quick │     │
│  └──────┘ └──────┘     │
│                          │
│  [Manage Workspaces]     │
└─────────────────────────┘
```

#### 2. Workspace Management

Settings → Workspaces → list view:
- Tap workspace → edit: name, description, icon, skills, policy, mount, model
- Skills shown as toggleable chips from the server's skill pool
- Policy as a segmented control (Container / Restricted)
- Host mount as a text field (validated server-side)

#### 3. Session List — Workspace Badge

Each session shows its workspace name/icon as a badge so you know what
context it's running in.

### WebSocket Protocol

No changes needed. Workspaces are a session-creation concern. Once a session
is running, the protocol is identical.

### Migration

Existing sessions have no `workspaceId`. Treat as "general" workspace.
On first launch after update, create default workspaces for existing users.

## Implementation Order

1. **`src/skills.ts`** — Skill registry (scan host skills, expose metadata)
2. **`src/types.ts`** — Add `Workspace` type, `workspaceId` to `Session`
3. **`src/storage.ts`** — Workspace CRUD + default seeding
4. **`src/sandbox.ts`** — Workspace-aware `initSession()` + `syncSkills()`
5. **`src/server.ts`** — REST endpoints for workspaces + skills
6. **iOS models** — `Workspace`, `SkillInfo` types
7. **iOS API** — `APIClient` methods for workspace/skill endpoints
8. **iOS UI** — Workspace picker, management screen

Steps 1–5 are server-only and testable with curl.
Steps 6–8 are iOS and can happen in parallel or after.

## Example Flow

```
1. User opens Pi Remote on phone
2. Taps "+" to create session
3. Sees workspace grid: [coding] [research] [personal] [quick]
4. Taps "coding"
5. Server creates session with workspaceId → loads coding workspace
6. Sandbox syncs ast-grep, tmux, web-browser, searxng, fetch into container
7. Mounts ~/workspace/pios as /work
8. Generates system prompt mentioning available skills
9. Agent starts with coding-optimized environment
10. User sends "find all TODO comments in the codebase"
11. Agent uses ast-grep skill, searches /work, reports results
```

## Future Extensions

- **Workspace templates** — share workspace configs (export/import JSON)
- **Per-workspace learned rules** — "Always Allow git push" only in coding workspace
- **Workspace-local skills** — create skills from phone, stored per workspace
- **Workspace cloning** — duplicate and modify
- **Quick workspace from URL** — scan QR or paste URL to import workspace config
