# Workspace = Container: Design Spike

## The Insight

A workspace isn't metadata on a session — it IS the container. It's the agent's
programming environment: files, skills, memory, processes. The iOS app is a
management console for these environments. Chat is just one view into the workspace.

**Current model (broken):**
```
Session → Container → pi process → single conversation
Workspace = label attached to session
```

**New model:**
```
Workspace → Container (persistent, managed sandbox)
  ├── Sessions (independent pi processes, each a conversation)
  │   ├── Session A: "research quantum computing"     [running]
  │   ├── Session B: fork of A, different approach     [running]
  │   └── Session C: "summarize papers"                [idle]
  ├── Files (persist across all sessions)
  ├── Skills (tools available to every session in this workspace)
  ├── Memory (shared remember/recall namespace)
  └── Permissions (policy rules scoped to this workspace)
```

## Document Ownership (Avoid Doc Drift)

- `README.md` — current user-facing setup and currently implemented API surface.
- `IMPLEMENTATION.md` — execution checklist and acceptance criteria.
- `WORKSPACE-CONTAINERS.md` (this doc) — target architecture + migration design.
- `DESIGN.md` — broader product/system design; some sections are historical context.
- `WORKSPACES.md` — concise workspace contract summary + pointers (not roadmap owner).

If documents conflict, precedence is:
1. `IMPLEMENTATION.md` for delivery status and phase scope
2. `WORKSPACE-CONTAINERS.md` for target architecture decisions
3. `README.md` for currently shipped behavior

## User Mental Model

"I have a **Research** workspace. It has web search, fetch, and note-taking skills.
I can run multiple conversations at once — one doing research, another writing a
summary. They share the same files and tools. If a conversation goes sideways,
I fork it and try again."

Non-techies understand workspaces. They don't understand containers, sessions,
or JSONL files. The workspace IS the thing they manage.

---

## Multiple Sessions per Workspace

The workspace is a managed container. Sessions are independent pi processes
running inside it. Like having multiple terminal windows open in the same
project directory.

```
Workspace "Research"
├── Container (Apple sandbox, persistent filesystem)
│   ├── Pi process 1 → Session A (active, streaming to phone)
│   ├── Pi process 2 → Session B (running in background)
│   └── Session C's JSONL (process stopped, resumable)
```

**Why multiple processes:**
- Agent does long research in Session A while you chat in Session B
- Fork creates a new process, original keeps running
- Natural for "run this in the background, I'll check later"
- Each pi process has its own context window, model, thinking level

**Concurrency model:**
- Each session = independent pi process with its own RPC channel
- Shared filesystem (workspace directory) — agents see each other's files
- Shared skills directory — all sessions have the same tools
- Independent permission gates — each process has its own TCP gate port
- Phone streams one session at a time (WS), but all run independently

**Resource limits:**
- Max concurrent sessions per workspace (default: 3)
- Max concurrent sessions across all workspaces (default: 5)
- Idle timeout per session (stop process, keep JSONL)
- Idle timeout per workspace (stop container after all sessions idle)

---

## Skills: The Core Product

Skills are the primary value prop. A workspace without good skills is just a
chatbot. With the right skills, it's a specialized agent that knows how to
research, code, analyze data, or manage your infrastructure.

### What is a Skill

A skill is a directory containing `SKILL.md` (instructions) and optional
supporting files. Pi loads skills into the system prompt so the agent knows
what capabilities it has and how to use them.

```
my-skill/
├── SKILL.md           # Instructions (name, description, when to use, how)
├── templates/         # Optional: prompt templates, reference files
├── bin/               # Optional: helper scripts
└── examples/          # Optional: usage examples
```

Pi's skill format follows the [Agent Skills](https://agentskills.io) standard.
Skills are just instructions — they don't execute code themselves. They tell the
agent what tools exist and how to combine them.

### Skill Sources

```
Built-in skills (shipped with pi-remote)
  ├── searxng          # Private web search
  ├── fetch            # URL content extraction
  ├── web-browser      # Chromium automation
  ├── ast-grep         # Structural code search
  └── research-report  # Multi-source research synthesis

User skills (created by the agent, curated by you)
  ├── strava-analyzer  # Created in a session, saved to workspace
  └── budget-review    # Refined over multiple conversations

Imported skills (from GitHub)
  ├── github.com/user/skill-repo
  └── github.com/org/skill-collection
```

### Skill Lifecycle in the App

```
                    ┌─────────────┐
  GitHub import ──→ │   Review    │ ← Agent creates during session
                    │  (pending)  │
                    └──────┬──────┘
                           │ User approves (after security scan)
                    ┌──────▼──────┐
                    │   Active    │
                    │ (in workspace)│
                    └──────┬──────┘
                           │ User removes
                    ┌──────▼──────┐
                    │  Archived   │
                    └─────────────┘
```

### GitHub Import

Users can import skills from GitHub repos. The flow:

```
1. User pastes GitHub URL or searches
2. Server clones/fetches the repo (shallow clone)
3. Discovers skills (directories with SKILL.md)
4. Runs security scan
5. Shows scan results to user on phone
6. User reviews and approves/rejects
7. Approved skills copied into workspace
```

**What we clone:**
- Public repos: `git clone --depth 1`
- Pi packages: repos with `pi.manifest.json` (pi's package format)
- Direct skill directories: `github.com/user/repo/tree/main/skills/my-skill`
- Skill collections: repos with multiple skill directories

**Discovery within a repo:**
- Look for `pi.manifest.json` (pi package format — lists skills explicitly)
- Scan for `**/SKILL.md` files (agent skills standard)
- Each directory containing SKILL.md = one skill

### Security Scanning

Every skill goes through automated scanning before installation. The scan
catches common attack vectors: skills that try to exfiltrate data, install
backdoors, or escape the sandbox.

**Scan layers:**

```
Layer 1: Static analysis of SKILL.md
  - Check for instructions that encourage dangerous behavior
  - Flag references to: curl/wget to external URLs, environment variables,
    SSH keys, credentials, /etc/passwd, home directory outside workspace
  - Flag obfuscation attempts (base64-encoded commands, hex escapes)

Layer 2: Supporting file analysis
  - Scan shell scripts for: network access, process spawning, file access
    outside workspace, credential access, package installation
  - Scan Python/JS for: subprocess calls, os.system, eval/exec, network
    requests to non-local URLs, file operations outside workspace
  - Check for known malicious patterns (reverse shells, crypto miners)

Layer 3: Permission mapping
  - What tools does this skill instruct the agent to use?
  - What file paths does it reference?
  - Does it need network access? (searxng skill vs local-only skill)
  - Generate a permission summary: "This skill uses: bash, read, write.
    Accesses files in: /workspace. Network: yes (web search)."

Layer 4: Diff on update
  - When updating an imported skill, show what changed
  - Highlight new dangerous patterns that weren't in the previous version
  - Require re-approval for material changes
```

**Import hard constraints (must enforce):**
- Clone into a quarantine temp directory, never directly into active skills path
- Disable or ignore git hooks; never execute repo-provided scripts during scan
- Default deny submodules and Git LFS (explicit opt-in later)
- Size/time limits on fetch + scan (e.g. max repo size, max file size, scan timeout)
- Allowlist file types for deep scanning; treat unknown binaries as high risk
- No network egress during static scan, except trusted GitHub fetch endpoint

**Scan result (shown to user):**

```
┌─────────────────────────────────────┐
│  Skill: strava-analyzer             │
│  Source: github.com/user/strava-sk  │
│                                     │
│  ✅ No dangerous instructions       │
│  ✅ No suspicious scripts           │
│  ⚠️  Uses network (fetch skill)     │
│  ⚠️  Writes files to /workspace     │
│                                     │
│  Permissions needed:                │
│  • bash (python, data processing)   │
│  • read/write (workspace files)     │
│  • fetch (Strava API)               │
│                                     │
│  [ View SKILL.md ]  [ View Files ]  │
│                                     │
│  [ Reject ]          [ Install ]    │
└─────────────────────────────────────┘
```

**Risk levels:**
- 🟢 Clean: no flags, local-only, read-only tools
- 🟡 Caution: network access, file writes, bash usage
- 🔴 Danger: external URLs in scripts, credential references, obfuscation

**Implementation approach:**
- v1: Pattern-based static analysis (regex + AST for supported languages)
- v2: LLM-assisted review (have the agent analyze the skill for risks)
- The permission gate is still the last line of defense — even if a skill
  slips through scanning, dangerous tool calls still require phone approval

### Skill Storage

```
~/.pi-remote/skills/
├── built-in/                    # Shipped with pi-remote, read-only
│   ├── searxng/
│   ├── fetch/
│   └── web-browser/
├── user/<userId>/               # User-created skills
│   ├── strava-analyzer/
│   └── budget-review/
└── imported/<userId>/           # GitHub-imported skills
    ├── github.com/
    │   └── user/
    │       └── repo/
    │           ├── .git-info    # Source URL, commit, last updated
    │           ├── .scan-result # Last security scan result
    │           └── skill-name/
    │               └── SKILL.md
    └── registry.json            # Import metadata (source, version, scan status)
```

Workspace config references skills by name:
```json
{
  "skills": ["searxng", "fetch", "strava-analyzer", "github.com/user/repo/skill-name"]
}
```

When a workspace starts, the server symlinks (or copies) referenced skills
into the container's skill directory.

---

## iOS Navigation

```
┌──────────────────────────────────────┐
│  Workspaces  │  Skills  │  Settings  │   ← Tab bar
└──────────────┴──────────┴────────────┘
```

### Workspaces Tab

```
┌─────────────────────────────────────┐
│  Research          ● 2 running      │
│  searxng, fetch, notes              │
│  Last: "quantum computing paper"    │
├─────────────────────────────────────┤
│  Coding            ○ Stopped        │
│  ast-grep, web-browser              │
│  Last: "refactor auth module"       │
├─────────────────────────────────────┤
│  +  New Workspace                   │
└─────────────────────────────────────┘
```

Tap → Workspace Detail:
```
┌─────────────────────────────────────┐
│  Research                    ⚙️     │
│  claude-sonnet-4 · 2 sessions      │
│                                     │
│  Sessions                           │
│  ┌─────────────────────────────────┐│
│  │ ● quantum computing      2m ago││  ← streaming to phone
│  │ ● paper analysis        12m ago││  ← running in background
│  │   summarize arxiv           3d ││  ← stopped, resumable
│  └─────────────────────────────────┘│
│                                     │
│  [ + New Session ]                  │
│                                     │
│  Skills (4)                         │
│  searxng · fetch · notes · web-br…  │
│                                     │
│  Files                              │
│  report.md · data/ · notes.md       │
└─────────────────────────────────────┘
```

### Skills Tab

Global skill management. Browse, import, create.

```
┌─────────────────────────────────────┐
│  Skills                             │
│                                     │
│  Built-in                           │
│  ┌─────────────────────────────────┐│
│  │ 🔍 searxng     Private search  ││
│  │ 🌐 fetch       URL extraction  ││
│  │ 🖥️ web-browser  Chromium       ││
│  │ 🔎 ast-grep    Code search     ││
│  └─────────────────────────────────┘│
│                                     │
│  My Skills                          │
│  ┌─────────────────────────────────┐│
│  │ 📊 strava-analyzer   Active    ││
│  │ 💰 budget-review     Active    ││
│  └─────────────────────────────────┘│
│                                     │
│  Imported                           │
│  ┌─────────────────────────────────┐│
│  │ 📦 user/research-tools  ✅     ││
│  │    3 skills · Updated 2d ago   ││
│  └─────────────────────────────────┘│
│                                     │
│  [ + Import from GitHub ]           │
└─────────────────────────────────────┘
```

Tap skill → Skill Detail:
```
┌─────────────────────────────────────┐
│  strava-analyzer                    │
│  Source: created in "Research"       │
│                                     │
│  Description:                       │
│  Analyze Strava activity exports.   │
│  Supports running, cycling, swim.   │
│                                     │
│  Used in workspaces:                │
│  • Research                         │
│  • Personal                         │
│                                     │
│  Files:                             │
│  SKILL.md · templates/ · bin/       │
│                                     │
│  Security: 🟢 Clean                 │
│  Last scanned: Feb 7, 2026          │
│                                     │
│  [ View SKILL.md ]                  │
│  [ Edit ]  [ Archive ]              │
└─────────────────────────────────────┘
```

Import flow:
```
[ + Import from GitHub ]
     ↓
┌─────────────────────────────────────┐
│  Import Skill                       │
│                                     │
│  GitHub URL:                        │
│  ┌─────────────────────────────────┐│
│  │ github.com/user/skill-repo     ││
│  └─────────────────────────────────┘│
│                                     │
│  [ Scan & Review ]                  │
└─────────────────────────────────────┘
     ↓ (scanning...)
┌─────────────────────────────────────┐
│  Scan Results                       │
│                                     │
│  Found 2 skills in repo:           │
│                                     │
│  ☑ data-viz       🟢 Clean         │
│    Chart and plot generation        │
│                                     │
│  ☑ web-scraper    🟡 Caution       │
│    ⚠️ Uses network (fetch)          │
│    ⚠️ Writes to workspace           │
│                                     │
│  [ Cancel ]       [ Install (2) ]   │
└─────────────────────────────────────┘
```

---

## Architecture

### Container Lifecycle

```
Workspace created → Config stored (skills, permissions, mount)
  ↓
First session started → Container created, skills synced
  ↓
Sessions run (multiple pi processes, shared filesystem)
  ↓
All sessions idle → Session processes stopped (JSONLs preserved)
  ↓
Workspace idle timeout → Container stopped (filesystem preserved on host)
  ↓
Next session started → Container restarted, skills re-synced
```

### Sandbox Directory Layout

```
~/.pi-remote/sandboxes/<userId>/<workspaceId>/
├── agent/                    # Pi home dir (shared by all sessions)
│   ├── auth.json             # Synced from host
│   ├── models.json           # Synced from host
│   ├── settings.json         # Generated per-workspace
│   ├── extensions/           # Permission gate + workspace extensions
│   │   └── permission-gate/
│   ├── skills/               # Skills synced for this workspace
│   │   ├── searxng/
│   │   ├── fetch/
│   │   └── strava-analyzer/
│   └── sessions/             # Pi session files (JSONL)
│       └── --work--/         # Encoded cwd
│           ├── 2026-02-07_abc.jsonl   ← Session A
│           ├── 2026-02-07_def.jsonl   ← Session B (fork of A)
│           └── 2026-02-07_ghi.jsonl   ← Session C
├── workspace/                # Working directory (bind-mounted or local)
│   ├── report.md             # Files persist across sessions
│   └── data/
└── memory/                   # Workspace memory namespace (optional)
```

### Server Components

**`workspace-runtime.ts`** (replaces `sessions.ts`):

```typescript
interface ActiveWorkspace {
  workspaceId: string;
  userId: string;
  containerRunning: boolean;
  sessions: Map<string, ActiveSession>;  // multiple concurrent
  maxConcurrentSessions: number;
}

interface ActiveSession {
  sessionId: string;
  workspaceId: string;
  process: ChildProcess;               // pi process
  subscribers: Set<(msg: ServerMessage) => void>;
  pendingResponses: Map<string, (data: any) => void>;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  partialResults: Map<string, string>;
  gatePort: number;                    // each session gets own gate port
  status: "starting" | "ready" | "busy" | "stopped";
}
```

Each session within a workspace:
- Has its own pi process (own RPC channel over stdin/stdout)
- Has its own permission gate TCP port
- Shares the workspace's container + filesystem + skills
- Can be started/stopped independently

**API endpoints:**

```
# Workspace management
GET    /workspaces                        → list workspaces
POST   /workspaces                        → create workspace
PUT    /workspaces/:id                    → update workspace config
DELETE /workspaces/:id                    → stop + delete workspace
POST   /workspaces/:id/start             → start container
POST   /workspaces/:id/stop              → stop container + all sessions

# Session management within workspace
GET    /workspaces/:wid/sessions          → list sessions (from storage index; reconcile with JSONL)
POST   /workspaces/:wid/sessions          → start new session (spawn pi)
POST   /workspaces/:wid/sessions/:sid/resume → resume stopped session
POST   /workspaces/:wid/sessions/:sid/stop   → stop session (kill pi)
POST   /workspaces/:wid/sessions/:sid/fork   → fork from entry

# Skills management
GET    /skills                            → list all available skills
GET    /skills/:name                      → skill detail + files
POST   /skills/import                     → import from GitHub
POST   /skills/import/:id/approve         → approve after scan
DELETE /skills/:name                      → archive/remove skill
POST   /skills/:name/scan                 → re-run security scan

# WebSocket (connect to a session within a workspace)
WS     /ws?token=...&workspace=...&session=...
```

**Session metadata source of truth:**
- `storage` remains authoritative for session metadata (name, status, counters, lineage)
- JSONL remains authoritative for conversation history/trace
- Reconciliation job repairs drift (e.g. crashed process, missing status update)

**New WebSocket messages:**

```typescript
// Server → Client
| { type: "session_created"; sessionId: string; prefillText?: string }

// Client → Server
| { type: "fork"; entryId: string }
```

### Fork Flow

```
1. User long-presses user message → "Fork from here"
2. iOS calls REST: POST /workspaces/:wid/sessions/:sid/fork {entryId}
3. Server validates `entryId` against the source session JSONL
4. Server creates a new fork JSONL by copying only the entry chain up to `entryId`
   (single canonical path: file-level fork, no RPC `fork` on the live process)
5. Server spawns new pi process with `--session <forked-file>`
6. Response: {sessionId: "new", prefillText: "original user message"}
7. iOS opens new session, pre-fills composer
```

Key difference from single-process model: fork spawns a NEW pi process.
The original session keeps running undisturbed.

## Migration and Compatibility Contract (v1)

To avoid breaking the current iOS app while refactoring server internals:

1. Keep legacy endpoints alive during migration:
   - `GET/POST /sessions`
   - `GET /sessions/:id`
   - `WS /sessions/:id/stream`
2. Legacy session creation automatically binds to a default workspace.
3. New workspace-scoped APIs are additive (`/workspaces/:wid/...`) until iOS flips over.
4. After iOS ships workspace-aware flows, deprecate legacy routes in two steps:
   - Step A: log-only deprecation warnings
   - Step B: remove routes in a major protocol version bump

## Data Layout Migration Plan

Current runtime layout is session-scoped:

```
~/.pi-remote/sandboxes/<userId>/<sessionId>/...
```

Target layout is workspace-scoped:

```
~/.pi-remote/sandboxes/<userId>/<workspaceId>/...
```

Migration strategy:

1. On server startup, detect legacy session-scoped sandboxes.
2. Create/resolve destination workspace for each legacy session.
3. Move `workspace/`, `agent/sessions/`, and session metadata into the workspace home.
4. Rebuild storage indexes (`session -> workspaceId`, path pointers).
5. Write a migration marker to avoid repeat work.
6. Keep rollback metadata (`.migrated-from`) for manual recovery.

No session data deletion during migration; cleanup is a separate explicit maintenance task.

## Concurrency Invariants

To keep behavior deterministic under races:

- Per-workspace mutex for lifecycle transitions (`start`, `stop`, `delete`).
- Per-session mutex for process transitions (`spawn`, `abort`, `kill`, `resume`).
- Reject `spawn session` when workspace state is `stopping`.
- Workspace stop is two-phase:
  1. Mark workspace `stopping` (block new sessions)
  2. Stop all sessions, then stop container.
- Gate port allocation is owned by session lifecycle; always release on process exit/error paths.

## Operational Limits and Config

Limits should be explicit config, not hardcoded:

```json
{
  "maxSessionsPerWorkspace": 3,
  "maxSessionsGlobal": 5,
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000
}
```

Enforcement order when starting a session:
1. Global cap
2. Workspace cap
3. Workspace/container health

## API / Protocol Versioning

WebSocket and REST schema changes should be versioned.

- Include protocol version in handshake or headers (`X-PiRemote-Protocol`).
- Additive fields are allowed without bump.
- Required field/behavior changes require a version bump and compatibility window.
- Keep iOS decoding backward-compatible for at least one server release.

---

## Phasing

### Phase 0: Workspace-scoped containers (server refactor)
- Container lifecycle tied to workspace, not session
- Multiple pi processes per workspace (each session = process)
- Shared filesystem, skills directory, memory
- Permission gate per-session (each pi process gets own gate port)
- Old iOS continues to work (session creation wraps workspace start)
- **Effort: 2-3 days, medium risk**

### Phase 1: Session management API
- REST endpoints for session list/create/resume/stop within workspace
- WebSocket connects to workspace + session
- Session list from storage index (with background JSONL reconciliation)
- **Effort: 1-2 days, low risk**

### Phase 2: iOS — Workspaces tab
- Replace Sessions tab with Workspaces tab
- Workspace list → workspace detail (session list + skills + files)
- Tap session → Chat view
- New session button, resume stopped session
- **Effort: 2-3 days, low risk**

### Phase 3: Fork
- Long-press user message → Fork action
- Server-side fork (single path: copy ancestor chain to new JSONL, spawn new pi process)
- Pre-fill composer in new session
- Fork lineage display ("forked from Session A")
- **Effort: 1-2 days, low risk**

### Phase 4: Skills — import + scanning
- GitHub import endpoint (shallow clone, skill discovery)
- Security scanner (static analysis, permission mapping)
- iOS import flow (paste URL → scan → review → install)
- Skill detail view (files, security status, workspaces using it)
- **Effort: 3-4 days, medium risk** (scanner quality matters)

### Phase 5: Skills — creation from sessions
- Agent creates skill during conversation
- Server detects new SKILL.md in workspace
- Phone prompts: "Save as skill?"
- Review + approve → copied to user skills directory
- **Effort: 1-2 days, low risk**

### Phase 6: Workspace management
- Full workspace config from phone (skills, model, prompt, mount)
- File browser within workspace
- Start/stop workspace from phone
- Workspace templates ("Research", "Coding", "Personal")
- **Effort: 2-3 days, low risk**

## Non-Goals (v1)

- Cross-session file locking/coordination (same as multiple terminals today)
- Cross-workspace cache sharing
- Real-time collaborative editing conflict resolution
- Automatic skill trust federation across users
- LLM-only security scanning as sole gate (rule-based scanning + permission gate remain mandatory)

## Session Lifecycle and Prompt Caching

### How Session Stop/Resume Works

A session is a pi process. When it stops (user exits the app, idle timeout,
explicit stop), the process is killed but the JSONL session file is preserved.
When the session resumes, a new pi process is spawned with `--session <path>`.
Pi reads the JSONL, calls `buildSessionContext()` to reconstruct the full
message array from the entry tree, and `replaceMessages()` to reload the
agent's context. The conversation continues exactly where it left off.

```
Session running → pi process alive, JSONL growing
      ↓ (stop: idle timeout, user action, app exit)
Session stopped → process killed, JSONL preserved on disk
      ↓ (resume: user taps session, or new prompt)
Session running → new pi process, same JSONL, context rebuilt
```

### Prompt Caching: What Actually Happens

This section is Anthropic-specific (current default provider behavior).
Other providers may have different cache semantics and TTLs.

Pi's Anthropic provider places `cache_control: { type: "ephemeral" }` on:
- System prompt blocks (skills, instructions)
- The last user message (cache breakpoint for conversation prefix)

Anthropic caches everything from request start up to the breakpoint. The
cache lives on Anthropic's servers, keyed by exact message prefix — not
by process or connection. Whether you have the same pi process or a brand
new one, if the messages are identical, the cache hits.

**Cache TTL:**
- Default (`cacheRetention: "short"`): ~5 minutes
- Long (`PI_CACHE_RETENTION=long`): 1 hour (api.anthropic.com only)
- Each API request that hits the cache extends the TTL

### Stop/Resume Impact on Caching

| Scenario | What happens | Cost impact |
|----------|-------------|-------------|
| Resume within 5 min | Cache HIT. Identical prefix matches. | Pay `cacheRead` (cheap, ~10% of input) |
| Resume after 5 min | Cache MISS. Full input tokens on first request. Cache re-established for subsequent. | One cold request, then cheap again |
| Resume after 1h (long retention) | Same as 5 min but with 1h window. | Depends on retention setting |
| Process stays alive, idle 10 min | Cache also expired. Keeping process alive doesn't help. | Same as resume after 10 min |
| Conversation after compaction | Cache MISS. Compaction rewrites the message array, breaking the prefix. | One cold request (but message array is smaller) |

**Key insight (Anthropic): keeping the pi process alive provides zero caching benefit.**
The cache is on Anthropic's side, keyed by request content. An idle process
that hasn't made API calls in 5+ minutes has the same cold cache as a
freshly spawned process. The only thing that keeps the cache warm is sending
requests within the TTL window.

### Practical Cost Numbers

For a typical conversation with 50K cached tokens:
- Cache read: ~$0.015 (vs ~$0.15 for full input) — 10x cheaper
- One cold resume: ~$0.15 extra on that single request
- Over a 20-message conversation: cache saves ~$2-3

The cost of resuming a session is one cache-cold request. For most
conversations, this is pennies. Not worth optimizing process lifecycle
around caching.

### Recommended Timeouts

Given that caching is independent of process lifetime:

| Timeout | Value | Rationale |
|---------|-------|-----------|
| Session idle (stop process) | 10 minutes | Saves memory + API token exposure. Resume is cheap. |
| Workspace idle (stop container) | 30 minutes | Container restart is heavier (~5-10s) but still acceptable. |
| Session idle while streaming to phone | Never | Don't timeout while user is actively watching. |
| Background session idle | 30 minutes | Background tasks may be long-running. |

### What Users Should See

In the iOS app, session status should communicate clearly:

```
● Running    — pi process alive, ready for prompts
○ Stopped    — process stopped, files preserved, tap to resume
◐ Resuming   — spawning process, rebuilding context (2-5s)
```

"Stopped" sessions are free (no process, no memory, no API calls). Users
should feel comfortable having many stopped sessions. The design should
encourage "start conversations freely, they're cheap to resume."

### Multiple Concurrent Sessions and Caching

Each session has its own conversation history, so each has an independent
cache on Anthropic's side. Two sessions in the same workspace don't share
a cache (different messages = different prefix). This means:

- 3 concurrent sessions = 3 independent caches
- Each warms its own cache on first request
- No interference between sessions
- System prompt is often shared across sessions in the same workspace,
  so that prefix portion may get cache hits even for new sessions

## Failure Modes and Recovery Expectations

| Failure | Expected behavior |
|---------|-------------------|
| Container fails to start | Session create/resume returns error; workspace marked degraded; retry action exposed |
| Pi process exits unexpectedly | Session marked stopped/error; gate port released; user sees resumable state |
| Permission gate unreachable | Fail closed: tool calls blocked; explicit warning shown in chat/session status |
| Skill sync failure | Workspace start fails with actionable error (which skill/path failed) |
| Auth token expired | Prompt fails fast with re-auth guidance; no silent retries looping forever |
| Storage write failure | Session updates rejected; server surfaces error and avoids partial metadata writes |

## Open Questions

1. **Concurrent file access** — Two sessions writing to the same file.
   Pi doesn't coordinate. Accept it? Warn? Use file locks?
   Probably accept for v1 — same as two terminals in the same directory.

2. **Session process limits** — How many pi processes per workspace?
   Default 3 feels right. Each consumes memory + API tokens.

3. **Skill updates** — When a GitHub skill updates, how do we notify?
   Periodic check? Manual refresh? Auto-update with re-scan?

4. **Skill sharing** — Can two users share skills? Probably yes via
   the same GitHub repo. But user-created skills are per-user for now.

5. **LLM-assisted skill scanning** — v2 idea: have the agent itself
   review the skill for risks. Meta but effective. "Here's a skill
   someone wants to install. What could go wrong?"
