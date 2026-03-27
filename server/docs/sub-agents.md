# Sub-agents

Oppi's `spawn_agent` extension lets agents create and manage child sessions within a workspace. The parent agent delegates tasks, monitors progress, and collects results — all without leaving its own context.

## Tools

The extension registers five tools. Root sessions get all five; child sessions get `check_agents`, `inspect_agent`, and `send_message` only (no spawning or stopping).

### spawn_agent

Create a new session in the current workspace.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `message` | string | required | Task prompt for the child. Include all context — the child has no access to the parent's conversation. |
| `name` | string | truncated message | Display name shown in the app and `check_agents` output. |
| `model` | string | inherited | Model override (e.g. `anthropic/claude-sonnet-4-6`). Omit to inherit from parent. |
| `thinking` | string | inherited | Thinking level: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. |
| `detached` | boolean | `false` | If true, creates an independent session with no parent-child link. Gets full capabilities including its own `spawn_agent`. Monitored from the app, not via `check_agents`. |
| `wait` | boolean | `false` | If true, blocks until the child finishes and returns its final response inline. |
| `timeout_seconds` | number | 1800 | Max seconds to wait (only when `wait=true`). |

**Fire-and-forget** (default): returns immediately with the child's session ID. Use `check_agents` to poll progress.

**Wait mode** (`wait=true`): blocks the parent's context until the child reaches a terminal state. Returns the child's last response, cost, changed files, and duration. Use for sequential dependencies where the parent needs the result before continuing.

### check_agents

Poll child session status.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `scope` | `"children"` \| `"workspace"` | `"children"` | `children`: direct children of this session. `workspace`: all active sessions in the workspace. |

Returns status, message count, cost, duration, and cache warmth hints for stopped children.

### inspect_agent

Progressive-disclosure trace inspection. Three levels of detail:

1. **Overview** (`inspect_agent(id)`) — turn count, tool breakdown, error markers, changed files. Start here.
2. **Turn detail** (`inspect_agent(id, turn: N)`) — tool list with condensed args and error previews for a specific turn.
3. **Tool detail** (`inspect_agent(id, turn: N, tool: M)`) — full tool arguments and output.

Set `response: true` to get the full assistant response text (no truncation). Combine with `turn` to get a specific turn's response.

Works on both active and stopped sessions — the trace is read from the session's JSONL file.

### send_message

Send a message to another session in the workspace.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | string | required | Target session ID. |
| `message` | string | required | Message content. |
| `behavior` | `"steer"` \| `"followUp"` | `"steer"` | How to deliver when the target is busy. |

Delivery depends on the target's state:
- **Idle**: starts a new turn (prompt).
- **Busy + steer**: injected after current tool calls finish, before the next LLM call. Use for course corrections.
- **Busy + followUp**: queued until the current turn finishes. Use for "do this next."
- **Stopped**: the session is automatically resumed and the message is delivered as a new prompt. Resuming within ~5 minutes of the child stopping benefits from prompt cache hits.

An agent-origin preamble (`[From agent "Name" (id)]`) is prepended so the recipient knows the source.

### stop_agent

Stop a running child session. Only works on sessions in the caller's spawn tree (not workspace-wide).

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Session ID to stop. |

## Spawn tree

Sessions form a tree: each child tracks its `parentSessionId`. The tree has a max depth of 1 — children cannot spawn their own children (use `detached: true` for independent sessions that need spawn capability).

The iOS app renders the spawn tree with a collapsible status bar showing each child's state, cost, and duration. The parent session's cost aggregates the full tree.

## Git safety

All agents in a workspace share the same working directory. For tasks that touch different files, parallel spawning is safe. For larger changes that overlap, run agents sequentially or use git worktrees.

## Workspace configuration

The `spawn_agent` and `ask` extensions are enabled by default. To disable them for a specific workspace, use the `extensions` field in workspace settings. When `extensions` is set, only the listed extensions are loaded — omitting `spawn_agent` or `ask` disables them for that workspace.
