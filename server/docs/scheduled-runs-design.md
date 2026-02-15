# Scheduled Async Runs — Design

Last updated: 2026-02-09 (revised: immediate triggers, silent completion, croner — adopted from pi-mom)

## Problem

Pi Remote has strong interactive supervision (chat + permission gate), but no first-class way to run unattended jobs on a schedule.

Target workflow (Mitchell-style):
- Kick off bounded async work at end-of-day
- Wake up to a digest / artifacts
- Delegate only high-confidence tasks
- Keep strict safety boundaries

This design adds **scheduled, unattended agent runs** with:
1. container-only execution
2. explicit per-run tool allow configuration from iOS
3. fail-closed permission behavior (no silent escalation)
4. reproducible run history and outputs

---

## Goals

1. **Container-only automation**
   - Scheduled runs must execute in container runtime.
   - Host runtime is not eligible for unattended runs.

2. **User-configurable tool policy per run**
   - iOS user picks allowed tools/execs/domains/paths.
   - Anything outside that policy is denied.

3. **Unattended-safe behavior**
   - No blocking on phone approvals by default.
   - `ask` decisions are auto-denied (or fail-run) in unattended mode.

4. **Clear morning outcomes**
   - Each run yields status + summary + artifact links.
   - Push notifications are digest-style, not spam.

5. **Fits existing architecture**
   - Reuse `SessionManager`, `GateServer`, `PolicyEngine`, `SandboxManager`.
   - Keep protocol and storage consistent with current patterns.

## Non-goals (v1)

- Multi-agent orchestration DAGs
- Automatic merge/deploy actions
- Cross-user shared schedules
- Running on host runtime

---

## User Mental Model

"A scheduled run is a saved background job for a workspace. It runs in a sandbox at specific times with only the tools I allowed."

Examples:
- Nightly issue triage report
- Morning research digest
- Daily benchmark regression check
- Weekly dependency audit summary

---

## iOS Configuration Experience

## Information Architecture

Add **Automations** under each workspace (not a global tab in v1).

Entry points:
- Workspace detail: `Automations` row with count
- Workspace edit: `Manage Automations`

Rationale:
- Schedules are workspace-scoped (skills, mounts, model defaults)
- Keeps setup contextual and easier to reason about

## Automation List Screen

`WorkspaceAutomationsView`
- Cards show:
  - run name
  - enabled/paused state
  - next run time
  - last run status (success/failed/blocked/timed_out)
  - quick actions: Run Now, Pause/Resume

## Create/Edit Flow (Wizard)

`AutomationEditorView` (4 steps + review)

### Step 1 — Task

Fields:
- Name
- Prompt/instructions
- Optional template preset:
  - Research Digest
  - Issue/PR Triage
  - Repo Health Check
  - Benchmark Watch
- Model override (optional)

Validation:
- Prompt required
- Name required

### Step 2 — Schedule

Modes:
- Daily (time + timezone)
- Weekly (days + time + timezone)
- Interval (every N minutes, min 30)
- Advanced cron (optional text mode)

Other controls:
- Overlap policy: `skip | queue | replace`
- Missed runs after downtime: `skip | run_once_on_start`

### Step 3 — Safety (Allowed Tools)

This is the core differentiator.

Preset profiles:
- **Read-only research** (read/find/grep/ls + domain-limited fetch/browser)
- **Triage/reporting** (read + constrained bash + write in reports path)
- **Custom**

Custom policy controls:
- File tools:
  - read (on by default)
  - write/edit (toggle)
  - allowed path roots (workspace-relative)
- Bash:
  - enable/disable
  - executable allowlist chips (e.g. `git`, `gh`, `rg`, `npm`)
  - optional command glob list
- Networked skills:
  - fetch allowed domains
  - web-browser allowed domains
  - browser JS eval toggle (default off)

Guardrail UX:
- Runtime badge locked to **Container**
- Warning banner: "Unattended runs deny anything not listed here"

### Step 4 — Output & Notifications

Output:
- Summary file path (default `reports/automation/<run-name>/latest.md`)
- Keep last N executions (default 20)

Notifications:
- Notify on success (default off)
- Notify on failure/blocked (default on)
- Morning digest hour (optional)

### Review + Dry Run

Before enabling:
- Show effective policy summary
- Show next run time
- `Run now (dry run)` button

Dry run returns:
- status
- denied tool calls (if any)
- suggested policy tweaks

Enable toggle only after successful save.

## Execution History UX

`AutomationRunHistoryView`
- chronological run list
- filters: success / failed / blocked
- each run shows:
  - start/end/duration
  - session link (open chat trace)
  - summary preview
  - denied policy events

---

## Server Architecture

## New Components

### 1) `src/schedules.ts` (store + validation)

Responsibilities:
- CRUD for scheduled run configs
- compute `nextRunAt`
- validate workspace/runtime/tool policy config

### 2) `src/scheduler.ts` (trigger loop + file watcher)

Responsibilities:
- in-memory timer queue for enabled runs (via `croner`)
- `fs.watch` on `events/<userId>/` for immediate triggers
- startup reconciliation (`skip` or `run_once_on_start`)
- stale immediate event cleanup on startup
- overlap policy enforcement
- global and per-workspace concurrency caps

### 3) `src/schedule-runner.ts` (execution orchestration)

Responsibilities:
- spawn scheduled session
- apply unattended policy mode
- send prompt
- monitor until completion/timeout/failure
- persist execution record + summary

### 4) `src/schedule-policy.ts` (policy compiler)

Responsibilities:
- compile user allow config to gate-enforced rules
- generate session-scoped allow rules
- enforce default deny for unattended runs

---

## Data Model (TypeScript)

```ts
interface ScheduledRun {
  id: string;
  userId: string;
  workspaceId: string;

  name: string;
  enabled: boolean;
  prompt: string;
  template?: "research_digest" | "triage" | "repo_health" | "benchmark_watch";
  model?: string;

  schedule: ScheduleSpec;
  overlapPolicy: "skip" | "queue" | "replace";
  missedRunPolicy: "skip" | "run_once_on_start";

  maxDurationMs: number; // default 30m

  unattended: {
    onAsk: "deny"; // v1 fixed behavior
    onDeny: "continue" | "fail_run"; // default fail_run
  };

  policy: ScheduledRunPolicy;
  output: ScheduledRunOutput;
  notifications: ScheduledRunNotifications;

  createdAt: number;
  updatedAt: number;
  lastRunAt?: number;
  nextRunAt?: number;
}

type ScheduleSpec =
  | { kind: "daily"; hour: number; minute: number; timezone: string }
  | { kind: "weekly"; days: number[]; hour: number; minute: number; timezone: string }
  | { kind: "interval"; everyMinutes: number }
  | { kind: "cron"; expression: string; timezone: string };

interface ScheduledRunPolicy {
  filePaths: {
    readRoots: string[];      // e.g. [".", "reports/"]
    writeRoots: string[];     // e.g. ["reports/"]
    editRoots: string[];      // e.g. ["reports/"]
  };

  bash?: {
    enabled: boolean;
    executables: string[];    // e.g. ["git", "gh", "rg"]
    commandGlobs?: string[];  // optional
  };

  fetchDomains?: string[];
  browserDomains?: string[];
  browserEvalAllowed?: boolean;
}

interface ScheduledRunOutput {
  summaryPath: string;        // workspace-relative path
  keepHistory: number;        // default 20
}

interface ScheduledRunNotifications {
  onSuccess: boolean;
  onFailure: boolean;
  onBlocked: boolean;
}

interface ScheduledExecution {
  id: string;
  runId: string;
  userId: string;
  workspaceId: string;
  sessionId: string;

  status: "running" | "success" | "failed" | "blocked" | "timed_out" | "cancelled";
  trigger: "schedule" | "manual" | "catchup" | "immediate";
  silent?: boolean;           // true if agent responded [SILENT] (nothing to report)

  startedAt: number;
  endedAt?: number;
  durationMs?: number;

  summaryPath?: string;
  deniedEvents: Array<{ tool: string; summary: string; reason: string }>;
  error?: string;
}
```

---

## Container-Only Enforcement

Validation at create/update/run time:
- `workspace.runtime` must be `container`
- reject with `400` for host workspaces

iOS behavior:
- host workspaces do not show "Create Automation"
- existing automations become "Invalid runtime" if workspace changed to host

---

## Permission + Policy Behavior (Unattended)

## Key invariant

Scheduled unattended runs never wait on a phone tap.

Implementation:
1. Create run session with policy preset `scheduled` (new preset, default deny).
2. Compile run policy into **session-scoped allow rules** in `RuleStore`.
3. Gate behavior for unattended sessions:
   - if policy result is `ask`, immediately deny
   - optionally mark run `blocked` and stop (default)

This gives deterministic behavior and removes timeout stalls.

## New preset: `scheduled`

- Hard denies: same critical denies as `container` preset
- Default action: `deny`
- No broad allow rules
- Allows only what run policy explicitly grants

## Rule compilation strategy

- File tools map to `pathPattern`-scoped allow rules
- Bash allowlist maps to executable rules (`match.executable`)
- Optional command globs map to `match.commandPattern`
- Domain lists map to `match.domain` for fetch/browser requests
- All scoped to `session` and cleared automatically on session end

Important: these run rules do **not** mutate global user policy.

---

## Execution Lifecycle

1. Scheduler triggers run
2. Server creates session (workspace-bound, container runtime)
3. Start pi process via existing `SessionManager.startSession(...)`
4. Attach run metadata (`source=scheduled`, `runId`, `executionId`)
5. Send prompt with run output contract
6. Observe events (`agent_end`, `session_ended`, policy denies, timeout)
7. On completion:
   - persist `ScheduledExecution`
   - write/update summary file in workspace
   - optional push notification
8. Stop session (or keep stopped state for inspection)

Timeout behavior:
- hard timeout (`maxDurationMs`) -> abort then force stop -> `timed_out`

---

## API Additions

```http
GET    /workspaces/:wid/scheduled-runs
POST   /workspaces/:wid/scheduled-runs
GET    /scheduled-runs/:id
PUT    /scheduled-runs/:id
DELETE /scheduled-runs/:id

POST   /scheduled-runs/:id/run-now
POST   /scheduled-runs/:id/pause
POST   /scheduled-runs/:id/resume

GET    /scheduled-runs/:id/executions?limit=50&before=<ts>
GET    /scheduled-runs/:id/executions/:execId
```

Optional WS events (for live UI updates):
- `scheduled_run_updated`
- `scheduled_execution_started`
- `scheduled_execution_finished`

---

## Storage Layout

```text
~/.config/oppi-server/
├── scheduled-runs/<userId>/<runId>.json
├── scheduled-executions/<userId>/<runId>/<execId>.json
└── events/<userId>/                    # immediate trigger drop zone
    └── <filename>.json                 # deleted after processing
```

Execution summaries are also written into workspace files (user-visible artifacts), not only server state.

---

## Security Invariants

1. Scheduled runs are container-only.
2. Hard denies remain immutable.
3. Unattended mode never waits for approvals.
4. Tool access is explicit and least-privilege.
5. Run-specific policy does not leak into global allow rules.
6. Full audit trail for allow/deny decisions and run outcomes.

---

## Reliability / Ops

- Global concurrency cap for scheduled runs (default 2)
- Per-workspace scheduled cap (default 1)
- Overlap policy respected per run
- Startup reconciliation for missed runs
- Jitter (0-30s) optional to avoid burst at exact minute boundaries

Failure classes surfaced in run status:
- `blocked` (policy denied required tool)
- `failed` (agent error / crash)
- `timed_out`
- `cancelled`

---

## Implementation Plan

### P0 — Server core (no iOS UI)
- Add scheduled run types + storage
- Add scheduler loop + run-now endpoint (`croner` for cron parsing)
- Add immediate trigger file watcher (`events/` dir)
- Add unattended mode + scheduled preset + session rule compilation
- Add execution history persistence (with `silent` detection)
- Add `[SILENT]` completion handling (suppress push, still persist)

### P1 — iOS CRUD + Run History
- Add Automations list + editor wizard
- Add run-now/pause/resume
- Add execution list/detail views

### P2 — Policy UX hardening
- Dry-run in editor
- Effective policy preview
- denied-call suggestions

### P3 — Workspace-runtime integration
- After workspace-scoped runtime lands, bind schedules to workspace container lifecycle
- Preserve APIs; optimize container warm starts

---

## Open Questions

1. Should `onDeny` default to `fail_run` or `continue` for report-oriented jobs?
2. ~~Do we expose raw cron in v1 or hide behind daily/weekly/interval presets?~~ **Resolved:** Yes, expose raw cron in v1 via `croner`. See below.
3. Should scheduled runs retain their session chat indefinitely or auto-prune?
4. Should summary generation be agent-written only, or server-generated fallback too?

---

## Patterns Adopted from pi-mom

Three patterns from `@mariozechner/pi-mom` (Slack bot agent) that strengthen this design.

### 1. Immediate Triggers via File Watch

Mom uses a watched `events/` directory where external systems drop JSON files to
trigger agent runs instantly. This completes the trigger model beyond cron/interval.

**Adoption:**

Add `immediate` as a trigger source alongside `schedule` and `manual`:

```ts
// New trigger type in ScheduledExecution
trigger: "schedule" | "manual" | "catchup" | "immediate";

// Immediate event file format (dropped into events dir)
interface ImmediateEvent {
  runId: string;         // which ScheduledRun to trigger
  text?: string;         // optional context appended to prompt
  source?: string;       // "ci", "webhook", "script" (for audit)
}
```

Implementation:
- `src/scheduler.ts` watches `~/.config/oppi-server/events/<userId>/` with `fs.watch`
- On new `.json` file: validate, resolve `runId`, trigger execution
- File is deleted after processing (same as mom)
- Respects overlap policy and concurrency caps
- Stale files (created before server start) are discarded on startup

Use cases:
- CI pipeline drops `{"runId":"nightly-triage","text":"Build #4521 failed"}` on failure
- Cron job on another machine writes an event via SSH/rsync
- User scripts trigger bounded agent work without opening iOS

### 2. Silent Completion (`[SILENT]`)

Mom's periodic jobs can respond with `[SILENT]` when they find nothing actionable,
suppressing the Slack message entirely. Same pattern prevents notification spam.

**Adoption:**

Add silent detection to execution completion in `src/schedule-runner.ts`:

```ts
// After agent completes, check last assistant message
const isSilent = finalText.trim() === "[SILENT]"
  || finalText.trim().startsWith("[SILENT]");

if (isSilent) {
  execution.status = "success";
  execution.silent = true;
  // Skip push notification even if onSuccess=true
  // Still persist execution record for history
}
```

Add to `ScheduledExecution`:
```ts
silent?: boolean;  // true if agent signaled nothing to report
```

System prompt contract for scheduled runs includes:
```
If your periodic check finds nothing actionable, respond with just [SILENT].
This suppresses notifications. Still write to the summary file if useful.
```

iOS execution history shows silent runs as dimmed/collapsed by default.

### 3. Cron Parsing via `croner`

Mom uses the `croner` npm package for cron expression parsing with timezone support.
This resolves open question #2: expose raw cron in v1.

**Adoption:**

```bash
cd oppi-server && npm install croner
```

Use in `src/scheduler.ts`:
```ts
import { Cron } from "croner";

// Validate cron expression at create/update time
function validateCron(expression: string, timezone: string): Date | null {
  try {
    const job = new Cron(expression, { timezone });
    return job.nextRun();
  } catch {
    return null; // invalid expression
  }
}

// Schedule periodic runs
function scheduleCron(run: ScheduledRun): Cron {
  const spec = run.schedule;
  if (spec.kind !== "cron") throw new Error("Not a cron schedule");

  return new Cron(spec.expression, { timezone: spec.timezone }, () => {
    triggerExecution(run, "schedule");
  });
}
```

All `ScheduleSpec` kinds compile down to `croner` internally:
- `daily` → `${minute} ${hour} * * *`
- `weekly` → `${minute} ${hour} * * ${days.join(",")}`
- `interval` → timer-based (not cron)
- `cron` → passed through directly

iOS Step 2 (Schedule) exposes a "Custom cron" toggle that reveals a text field
with live validation and next-3-runs preview.

---

## Recommendation

Ship v1 with strict unattended behavior:
- container-only
- default deny
- explicit tool allowlist
- fail run on first unexpected permission (`onDeny=fail_run` default)

This matches Pi Remote's safety model and avoids ambiguous half-completed background runs.
