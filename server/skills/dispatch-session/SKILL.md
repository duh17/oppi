---
name: dispatch-session
description: "Dispatch tasks to oppi sessions, single or parallel. Creates sessions, starts agents, and sends prompts. This skill should be used when delegating coding tasks, reviews, refactors, or any parallelizable work to subagent sessions."
container: false
---

# Dispatch Session

Task delegation via the oppi server API. Creates sessions in a workspace, starts pi agent processes, sends prompts, and exits. Sessions run autonomously with full tool access and mobile supervision.

## Table of Contents

- [Usage](#usage)
- [Task Patterns](#task-patterns)
- [Parallel Dispatch](#parallel-dispatch)
- [Session Lifecycle](#session-lifecycle)
- [How It Works](#how-it-works)
- [References](#references)

## Usage

```bash
node {baseDir}/dispatch.mjs \
  --workspace <id|name> \
  --prompt "Task prompt here" \
  [--name "session-name"] \
  [--model "anthropic/claude-sonnet-4-5"] \
  [--thinking medium] \
  [--context-file "./path/to/spec.md"] \
  [--todo "TODO-9586cb93"]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--workspace` | Yes | Workspace ID or name |
| `--prompt` | Yes | Task prompt sent to the subagent |
| `--name` | No | Session name (visible in the oppi iOS app) |
| `--model` | No | Model override (defaults to workspace config) |
| `--thinking` | No | Thinking level: off, minimal, low, medium, high, xhigh |
| `--context-file` | No | Attach file content to prompt. Repeatable. Fails if missing/empty. |
| `--todo` | No | Inject full TODO content (e.g. `TODO-9586cb93`); fail-fast if not found |

Output (JSON to stdout):
```json
{
  "sessionId": "abc123",
  "workspaceId": "zs1JP9sA",
  "workspaceName": "my-project",
  "model": "anthropic/claude-sonnet-4-5",
  "prompted": true,
  "injectedTodos": ["TODO-9586cb93"],
  "injectedFiles": ["/path/to/spec.md"],
  "promptChars": 8123
}
```

## Task Patterns

### Code Review
```bash
node {baseDir}/dispatch.mjs --workspace proj --name "review: auth module" \
  --prompt "Review the authentication module for security issues, error handling gaps, and code clarity. Write findings to a markdown summary. Do not make changes."
```

### Test Coverage
```bash
node {baseDir}/dispatch.mjs --workspace proj --name "tests: session-protocol" \
  --prompt "Analyze test coverage for src/session-protocol.ts. Identify untested edge cases. Write new tests. Run npm test to validate."
```

### Exploration
```bash
node {baseDir}/dispatch.mjs --workspace proj --name "explore: SDK events" \
  --prompt "Investigate all event types emitted by the SDK. Document each type, payload shape, and when it fires. Write findings to /tmp/sdk-events.md."
```

## Parallel Dispatch

Dispatch multiple sessions to the same workspace when file sets are disjoint. Verify zero file overlap before dispatching. Include explicit boundary instructions in each prompt.

See [references/parallel-dispatch.md](references/parallel-dispatch.md) for prerequisites, dispatch/review/stop patterns, phased refactor examples, and the parallel-vs-worktree decision table.

For prompt structure guidance, see [references/prompt-engineering.md](references/prompt-engineering.md).

## Session Lifecycle

Orchestration flow for a parent agent managing dispatched sessions:

1. **Plan** — break work into TODOs with explicit file ownership
2. **Verify parallelism** — confirm file sets are disjoint
3. **Dispatch** — fire N sessions with scoped prompts
4. **Monitor** — oppi iOS app for real-time progress and permission approvals
5. **Review** — `git log`, `git show --stat`, grep for remaining issues
6. **Test** — run the full test suite to catch integration issues
7. **Stop** — stop completed sessions via API
8. **Close TODOs** — update status

For REST API details (status checks, stop, delete), see [references/api-reference.md](references/api-reference.md).

## How It Works

1. Read auth token from `~/.config/oppi/config.json`
2. `POST /workspaces/:id/sessions` — create the session
3. `POST /workspaces/:id/sessions/:id/resume` — start the pi process
4. Open WebSocket to `/stream`, subscribe, send the prompt
5. Disconnect once prompt is accepted — the agent runs autonomously

## References

- [references/parallel-dispatch.md](references/parallel-dispatch.md) — parallel safety, phased refactors, review/stop patterns
- [references/prompt-engineering.md](references/prompt-engineering.md) — prompt structure and guidelines for subagents
- [references/api-reference.md](references/api-reference.md) — session management REST API
