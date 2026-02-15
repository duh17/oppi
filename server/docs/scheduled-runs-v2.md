# Scheduled Runs — Implementation Spec

> Supersedes `scheduled-runs-design.md`. Incorporates OpenClaw cron patterns, current oppi architecture, and FSWatcher skill pipeline.

## What We're Building

Oppi-server gains a built-in scheduler that runs agent sessions on a schedule — no human in the loop. Jobs persist to disk, survive server restarts, and report results via push notification.

**Core loop:** `croner` timer fires → spawn pi in container → send prompt → collect output → push notification → done.

## Architecture Overview

```
┌─────────────┐     ┌──────────────┐     ┌───────────────────┐
│  iOS app    │────▶│  REST API    │────▶│  ScheduleStore    │
│  (CRUD UI)  │     │  /jobs/*     │     │  (~/.config/oppi/ │
└─────────────┘     └──────────────┘     │   jobs/<id>.json) │
                                          └────────┬──────────┘
                                                   │ load on boot
                                          ┌────────▼──────────┐
                                          │    Scheduler      │
                                          │  (croner timers)  │
                                          │  + event watcher  │
                                          └────────┬──────────┘
                                                   │ trigger
                                          ┌────────▼──────────┐
                                          │   JobRunner       │
                                          │  spawn session    │
                                          │  apply policy     │
                                          │  send prompt      │
                                          │  wait for end     │
                                          │  persist result   │
                                          │  push notify      │
                                          └───────────────────┘
```

---

## Files to Create

| File | Responsibility |
|------|----------------|
| `src/jobs.ts` | `ScheduleStore` — CRUD, persistence, validation |
| `src/scheduler.ts` | `Scheduler` — timer management, event watcher, trigger dispatch |
| `src/job-runner.ts` | `JobRunner` — execution orchestration (spawn → prompt → collect → notify) |
| `src/job-policy.ts` | `compileJobPolicy()` — convert job config into session-scoped allow rules |
| `tests/jobs.test.ts` | Store CRUD + validation |
| `tests/scheduler.test.ts` | Timer lifecycle, overlap, concurrency |
| `tests/job-runner.test.ts` | Execution flow, timeout, silent detection |
| `tests/job-policy.test.ts` | Policy compilation + deny behavior |

---

## Data Model

### Job (stored config)

```ts
interface Job {
  id: string;                    // nanoid
  workspaceId: string;
  name: string;
  enabled: boolean;
  prompt: string;                // agent instructions
  model?: string;                // override workspace default

  schedule: ScheduleSpec;
  overlapPolicy: "skip" | "cancel_previous";
  missedPolicy: "skip" | "run_once";

  maxDurationMs: number;         // default 1800000 (30m)

  policy: JobPolicy;
  notifications: JobNotifications;

  createdAt: number;
  updatedAt: number;
  lastRunAt?: number;
  nextRunAt?: number;
}

type ScheduleSpec =
  | { kind: "once"; at: string }                                    // ISO 8601
  | { kind: "daily"; hour: number; minute: number; tz: string }
  | { kind: "weekly"; days: number[]; hour: number; minute: number; tz: string }
  | { kind: "interval"; everyMs: number }                           // min 60000 (1m)
  | { kind: "cron"; expr: string; tz: string };

interface JobPolicy {
  // What files the agent can touch
  readPaths: string[];           // workspace-relative globs, default ["**"]
  writePaths: string[];          // default [] (read-only)

  // Bash access
  bash: {
    enabled: boolean;            // default false
    allowedExecutables: string[]; // e.g. ["git", "rg", "gh"]
  };

  // Network access
  fetchDomains: string[];        // e.g. ["github.com", "*.anthropic.com"]
  browserDomains: string[];      // default []

  // What happens when the agent tries something not allowed
  onDeny: "continue" | "fail";   // default "fail"
}

interface JobNotifications {
  onSuccess: boolean;            // default false (silent success)
  onFailure: boolean;            // default true
  silentSuppress: boolean;       // default true — skip push if agent says [SILENT]
}
```

### Execution (run history record)

```ts
interface JobExecution {
  id: string;                    // nanoid
  jobId: string;
  workspaceId: string;
  sessionId: string;             // the pi session created for this run

  status: "running" | "success" | "failed" | "timed_out" | "skipped" | "cancelled";
  trigger: "schedule" | "manual" | "event" | "catchup";
  silent: boolean;               // agent responded [SILENT]

  startedAt: number;
  endedAt?: number;
  durationMs?: number;

  summary?: string;              // extracted from agent's final message
  deniedTools: Array<{
    tool: string;
    args: string;
    reason: string;
  }>;
  error?: string;
}
```

---

## Storage Layout

```
~/.config/oppi/
├── jobs/
│   ├── <jobId>.json              # Job config
│   └── ...
├── job-runs/
│   ├── <jobId>/
│   │   ├── <execId>.json         # Execution record
│   │   └── ...
│   └── ...
└── job-events/                   # Immediate trigger drop zone
    └── <filename>.json           # Consumed + deleted after processing
```

Single flat dir for jobs (no userId nesting — single-owner mode).

---

## 1. ScheduleStore (`src/jobs.ts`)

```ts
class ScheduleStore {
  private jobs: Map<string, Job> = new Map();
  private baseDir: string;  // ~/.config/oppi/jobs/
  private runsDir: string;  // ~/.config/oppi/job-runs/

  // ── CRUD ──
  list(): Job[]
  get(id: string): Job | null
  create(input: CreateJobInput): Job        // validates, assigns id, computes nextRunAt
  update(id: string, patch: Partial<Job>): Job
  delete(id: string): boolean
  enable(id: string): Job
  disable(id: string): Job

  // ── Execution history ──
  recordExecution(exec: JobExecution): void
  getExecutions(jobId: string, opts?: { limit?: number; before?: number }): JobExecution[]
  getExecution(jobId: string, execId: string): JobExecution | null
  pruneExecutions(jobId: string, keep: number): void  // default keep 50

  // ── Schedule helpers ──
  computeNextRun(job: Job): number | null   // uses croner
  getEnabledJobs(): Job[]
  getOverdueJobs(now: number): Job[]        // for startup catchup
}
```

**Validation rules:**
- `name` required, 1-100 chars
- `prompt` required, 1-10000 chars
- `schedule` must produce a valid next run time via croner
- `maxDurationMs` min 60000 (1m), max 7200000 (2h)
- `policy.readPaths` default `["**"]`
- `policy.bash.allowedExecutables` each must be alphanumeric + hyphens (no paths)
- `interval.everyMs` min 60000 (1m)
- `once.at` must be a valid ISO 8601 datetime

---

## 2. Scheduler (`src/scheduler.ts`)

The scheduler manages timer lifecycle and dispatches triggers to the runner.

```ts
class Scheduler extends EventEmitter {
  private timers: Map<string, Cron> = new Map();  // jobId → croner instance
  private intervalTimers: Map<string, NodeJS.Timeout> = new Map();
  private running: Map<string, string> = new Map();  // jobId → execId (for overlap)
  private eventWatcher?: FSWatcher;

  constructor(
    private store: ScheduleStore,
    private runner: JobRunner,
    private opts: { maxConcurrent: number }  // default 2
  )

  // ── Lifecycle ──
  start(): void           // Load all enabled jobs, schedule timers, start event watcher
  stop(): void            // Cancel all timers, stop watcher

  // ── Job management ──
  scheduleJob(job: Job): void       // Create/replace timer for job
  unscheduleJob(jobId: string): void
  rescheduleAll(): void             // After bulk changes

  // ── Triggers ──
  triggerNow(jobId: string): Promise<JobExecution>  // Manual run-now
  private onTimerFire(job: Job): void               // Timer callback
  private onEventFile(filePath: string): void       // Event watcher callback

  // ── Overlap ──
  private canRun(job: Job): boolean  // Check concurrency + overlap policy

  // ── Startup ──
  private reconcileMissedRuns(): void  // Check overdue jobs, apply missedPolicy
}
```

**Timer types:**
- `once` → `setTimeout` to the target time, auto-delete job after success
- `daily`/`weekly`/`cron` → `new Cron(expr, { timezone }, callback)`
- `interval` → `setInterval(callback, everyMs)` with jitter

**Event watcher:**
- `fs.watch("~/.config/oppi/job-events/", { recursive: false })`
- On new `.json` file: read, validate `{ jobId, text?, source? }`, trigger, delete
- Stale files on startup (mtime < server start) are deleted without triggering

**Concurrency:**
- Global cap: `maxConcurrent` (default 2)
- Per-job: only 1 execution at a time (overlap policy applies)
- `skip`: if job is already running, skip this trigger
- `cancel_previous`: abort running execution, start new one

---

## 3. JobRunner (`src/job-runner.ts`)

Orchestrates a single job execution end-to-end.

```ts
class JobRunner {
  constructor(
    private sessions: SessionManager,
    private storage: Storage,
    private sandbox: SandboxManager,
    private push: PushService,
    private store: ScheduleStore,
    private policyCompiler: JobPolicyCompiler
  )

  async run(job: Job, trigger: JobExecution["trigger"], eventText?: string): Promise<JobExecution> {
    const exec: JobExecution = {
      id: nanoid(),
      jobId: job.id,
      workspaceId: job.workspaceId,
      sessionId: `job-${job.id}-${Date.now()}`,
      status: "running",
      trigger,
      silent: false,
      startedAt: Date.now(),
      deniedTools: [],
    };

    try {
      // 1. Create session in workspace
      const workspace = this.storage.getWorkspace(job.workspaceId);
      if (!workspace || workspace.runtime !== "container") {
        throw new Error("Job workspace must be container runtime");
      }

      const session = this.storage.createSession(workspace.userId, {
        id: exec.sessionId,
        workspaceId: workspace.id,
        name: `[job] ${job.name}`,
        model: job.model,
      });

      // 2. Compile and install session-scoped policy rules
      const rules = this.policyCompiler.compile(job);
      // Install rules into the gate for this session
      this.installSessionRules(exec.sessionId, rules);

      // 3. Start pi process
      await this.sessions.startSession(workspace.userId, exec.sessionId, undefined, workspace);

      // 4. Build and send prompt
      const prompt = this.buildPrompt(job, trigger, eventText);
      await this.sessions.sendPrompt(workspace.userId, exec.sessionId, prompt);

      // 5. Wait for completion with timeout
      const result = await this.waitForCompletion(exec.sessionId, job.maxDurationMs);

      // 6. Extract summary and detect [SILENT]
      exec.summary = result.lastMessage;
      exec.silent = this.isSilent(result.lastMessage);
      exec.status = "success";
      exec.endedAt = Date.now();
      exec.durationMs = exec.endedAt - exec.startedAt;

    } catch (err) {
      exec.status = err.message?.includes("timeout") ? "timed_out" : "failed";
      exec.error = err instanceof Error ? err.message : String(err);
      exec.endedAt = Date.now();
      exec.durationMs = exec.endedAt - exec.startedAt;
    } finally {
      // 7. Persist execution
      this.store.recordExecution(exec);
      this.store.update(job.id, { lastRunAt: exec.startedAt });

      // 8. Cleanup session-scoped rules
      this.removeSessionRules(exec.sessionId);

      // 9. Stop session
      try {
        await this.sessions.stopSession(workspace.userId, exec.sessionId);
      } catch {}

      // 10. Push notification
      this.notify(job, exec);

      // 11. Auto-delete one-shot jobs
      if (job.schedule.kind === "once" && exec.status === "success") {
        this.store.delete(job.id);
      }
    }

    return exec;
  }
}
```

**Prompt construction:**

```ts
private buildPrompt(job: Job, trigger: string, eventText?: string): string {
  const parts = [
    `[scheduled-job: ${job.name}]`,
    `Trigger: ${trigger}`,
    `Time: ${new Date().toISOString()}`,
    "",
    job.prompt,
  ];

  if (eventText) {
    parts.push("", "--- Event Context ---", eventText);
  }

  parts.push(
    "",
    "--- Output Contract ---",
    "• Write your findings/report as the final message.",
    "• If there is nothing actionable to report, respond with just: [SILENT]",
    "• You are running unattended. Do not ask questions — make decisions.",
    "• Tool calls outside your policy will be denied.",
  );

  return parts.join("\n");
}
```

**Silent detection:**

```ts
private isSilent(msg?: string): boolean {
  if (!msg) return false;
  const trimmed = msg.trim();
  return trimmed === "[SILENT]" || trimmed.startsWith("[SILENT]");
}
```

**Wait for completion:**

```ts
private waitForCompletion(sessionId: string, timeoutMs: number): Promise<{ lastMessage?: string }> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Job timed out"));
    }, timeoutMs);

    // Listen for agent_end event on this session
    const handler = (event: SessionEvent) => {
      if (event.sessionId === sessionId && event.type === "agent_end") {
        clearTimeout(timeout);
        this.sessions.off("event", handler);
        resolve({ lastMessage: event.lastMessage });
      }
    };
    this.sessions.on("event", handler);
  });
}
```

**Push notification:**

```ts
private async notify(job: Job, exec: JobExecution): void {
  // Skip if silent and suppression enabled
  if (exec.silent && job.notifications.silentSuppress) return;

  // Skip success notifications if not requested
  if (exec.status === "success" && !job.notifications.onSuccess) return;

  // Always notify on failure (unless disabled)
  if (exec.status !== "success" && !job.notifications.onFailure) return;

  const owner = this.storage.getOwnerUser();
  if (!owner?.pushToken) return;

  const title = exec.status === "success" ? `✅ ${job.name}` : `❌ ${job.name}`;
  const body = exec.summary?.slice(0, 200) || exec.error?.slice(0, 200) || "No output";

  await this.push.sendJobCompletionPush(owner.pushToken, {
    jobId: job.id,
    execId: exec.id,
    title,
    body,
    status: exec.status,
    durationMs: exec.durationMs,
  });
}
```

---

## 4. Job Policy Compiler (`src/job-policy.ts`)

Converts a `JobPolicy` into session-scoped gate rules.

```ts
class JobPolicyCompiler {
  compile(job: Job): SessionRule[] {
    const rules: SessionRule[] = [];

    // File read access
    for (const glob of job.policy.readPaths) {
      rules.push({
        tool: "read",
        pathPattern: glob,
        action: "allow",
        scope: "session",
      });
    }

    // File write access
    for (const glob of job.policy.writePaths) {
      rules.push({ tool: "write", pathPattern: glob, action: "allow", scope: "session" });
      rules.push({ tool: "edit", pathPattern: glob, action: "allow", scope: "session" });
    }

    // Bash access
    if (job.policy.bash.enabled) {
      for (const exec of job.policy.bash.allowedExecutables) {
        rules.push({
          tool: "bash",
          executable: exec,
          action: "allow",
          scope: "session",
        });
      }
    }

    // Fetch domains
    for (const domain of job.policy.fetchDomains) {
      rules.push({ tool: "bash", executable: "fetch", domain, action: "allow", scope: "session" });
    }

    // Browser domains
    for (const domain of job.policy.browserDomains) {
      rules.push({ tool: "bash", executable: "web-browser", domain, action: "allow", scope: "session" });
    }

    // Default deny for everything else (the "scheduled" preset handles this)
    return rules;
  }
}
```

**New policy preset: `scheduled`**

```ts
export const PRESET_SCHEDULED: PolicyPreset = {
  name: "scheduled",
  hardDeny: [
    // Same critical denies as container
    ...PRESET_CONTAINER.hardDeny,
  ],
  defaultAction: "deny",      // Everything not explicitly allowed is denied
  softAllow: [],               // No broad allows — job policy provides specifics
  askAction: "deny",           // Never wait for phone tap
};
```

---

## 5. REST API

```
GET    /jobs                              → list all jobs
POST   /jobs                              → create job
GET    /jobs/:id                          → get job details
PUT    /jobs/:id                          → update job
DELETE /jobs/:id                          → delete job

POST   /jobs/:id/run                      → trigger manual run
POST   /jobs/:id/enable                   → enable job
POST   /jobs/:id/disable                  → disable job

GET    /jobs/:id/runs                     → execution history (paginated)
GET    /jobs/:id/runs/:execId             → single execution detail
```

**WebSocket events (pushed to connected iOS clients):**

```ts
{ type: "job:started",   jobId, execId, trigger }
{ type: "job:completed", jobId, execId, status, summary?, durationMs }
{ type: "job:updated",   job }  // config changed
```

---

## 6. Server Wiring (`src/server.ts`)

```ts
// In constructor, after skillRegistry setup:
this.scheduleStore = new ScheduleStore(configDir);
this.jobPolicyCompiler = new JobPolicyCompiler();
this.jobRunner = new JobRunner(
  this.sessions,
  this.storage,
  this.sandbox,
  this.push,
  this.scheduleStore,
  this.jobPolicyCompiler,
);
this.scheduler = new Scheduler(this.scheduleStore, this.jobRunner, { maxConcurrent: 2 });

// After server is listening:
this.scheduler.start();

// In stop():
this.scheduler.stop();
```

---

## 7. iOS UI

### Information Architecture

Jobs live under each workspace (not a global tab):

```
Workspaces → [workspace] → Jobs (count badge)
                          → Job List
                            → Job Detail (run history, run now, edit)
                            → Job Editor (wizard)
```

### Job List View

- Cards with: name, schedule description, enabled toggle, last run status, next run time
- Swipe actions: Run Now, Delete
- Empty state: "No scheduled jobs. Tap + to create one."

### Job Editor (3-step wizard)

**Step 1 — What**: Name + prompt + model override
**Step 2 — When**: Schedule picker (daily/weekly/cron/once/interval)
**Step 3 — Safety**: Policy config (read paths, write paths, bash executables, fetch domains)

Review screen: effective policy summary + next 3 run times + "Run Now (test)" button.

### Execution History

- Chronological list per job
- Status badges: ✅ success, ❌ failed, ⏱ timed_out, 🔇 silent
- Tap to see: full session trace link, denied tools, summary, duration

### Push Notification

New APNs category: `JOB_COMPLETION`
- Title: `✅ Nightly Triage` or `❌ Research Digest failed`
- Body: First 200 chars of summary
- Tap → opens job execution detail in app

---

## 8. Implementation Order

### Phase 1: Server Core (no UI)
1. `src/jobs.ts` — ScheduleStore with CRUD + validation + persistence
2. `src/job-policy.ts` — Policy compiler + `PRESET_SCHEDULED`
3. `src/job-runner.ts` — Execution orchestrator
4. `src/scheduler.ts` — Timer management + event watcher
5. Wire into `server.ts`
6. REST API endpoints in `routes.ts`
7. Tests for each module
8. CLI: `oppi-server job create/list/run/delete` for testing without iOS

### Phase 2: iOS CRUD
9. Job models (`Job.swift`, `JobExecution.swift`)
10. `APIClient` methods for job CRUD
11. `JobListView` + `JobEditorView` (3-step wizard)
12. `JobExecutionListView`
13. Wire into workspace detail navigation

### Phase 3: Live Updates
14. WebSocket events for job status
15. Push notification for job completion
16. Live activity for long-running jobs (optional)

### Phase 4: Polish
17. Dry-run mode (compile policy, report what would be denied)
18. Execution history pruning
19. Job templates (research digest, triage, etc.)

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Container-only | Yes | Unattended runs need sandbox isolation |
| Default deny | Yes | Explicit allowlist, no surprises |
| No heartbeat | Skip for v1 | OpenClaw's heartbeat is for always-on chat; we don't need it |
| `onDeny: "fail"` default | Yes | Half-finished runs are worse than failed runs |
| Single-owner, no userId | Yes | Consistent with rest of oppi |
| croner for cron | Yes | Proven, timezone-aware, OpenClaw uses it too |
| Event watcher | Yes | CI/webhooks can trigger jobs without iOS |
| [SILENT] convention | Yes | Prevents notification spam for "nothing to report" |
| Session per execution | Yes | Clean context, no cross-contamination |
| Auto-delete one-shot | Yes | "Remind me in 20 min" should clean up |
| Max 2h duration | Yes | Prevents runaway jobs |

---

## Example Jobs

### Morning Research Digest
```json
{
  "name": "Morning Research Digest",
  "prompt": "Search for the latest news and papers on MLX, Apple Silicon ML, and local LLM inference. Write a concise digest with links. Focus on the last 24 hours.",
  "schedule": { "kind": "daily", "hour": 7, "minute": 0, "tz": "America/Los_Angeles" },
  "policy": {
    "readPaths": ["**"],
    "writePaths": ["reports/"],
    "bash": { "enabled": true, "allowedExecutables": ["search", "fetch", "rg"] },
    "fetchDomains": ["*"],
    "browserDomains": [],
    "onDeny": "continue"
  },
  "notifications": { "onSuccess": true, "onFailure": true, "silentSuppress": true }
}
```

### Nightly GitHub Triage
```json
{
  "name": "Nightly GitHub Triage",
  "prompt": "Check open issues and PRs on github.com/chenda/oppi. Summarize new issues, stale PRs, and CI failures. If nothing new, respond [SILENT].",
  "schedule": { "kind": "daily", "hour": 22, "minute": 0, "tz": "America/Los_Angeles" },
  "policy": {
    "readPaths": ["**"],
    "writePaths": [],
    "bash": { "enabled": true, "allowedExecutables": ["gh", "git", "rg"] },
    "fetchDomains": ["github.com", "api.github.com"],
    "browserDomains": [],
    "onDeny": "continue"
  },
  "notifications": { "onSuccess": false, "onFailure": true, "silentSuppress": true }
}
```

### One-Shot Reminder
```json
{
  "name": "Check deployment",
  "prompt": "Check if the latest deployment to production is healthy. Run health checks and report status.",
  "schedule": { "kind": "once", "at": "2026-02-14T10:00:00-08:00" },
  "policy": {
    "readPaths": ["**"],
    "writePaths": [],
    "bash": { "enabled": true, "allowedExecutables": ["curl", "jq"] },
    "fetchDomains": ["api.example.com"],
    "browserDomains": [],
    "onDeny": "fail"
  },
  "notifications": { "onSuccess": true, "onFailure": true, "silentSuppress": false }
}
```
