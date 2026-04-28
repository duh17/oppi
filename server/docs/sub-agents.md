# Sub-agents

Oppi's `subagents` extension lets agents create and manage child sessions within a workspace. The parent agent delegates tasks, monitors progress, and collects results — all without leaving its own context.

## Tools

The extension registers four tools. Root sessions get all four; child sessions get `inspect_agent` and `send_message` only (no spawning or stopping).

### spawn_agent

Create a new session in the current workspace.

| Parameter         | Type    | Default           | Description                                                                                                                                        |
| ----------------- | ------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `message`         | string  | required          | Task prompt for the child. Include all context — the child has no access to the parent's conversation.                                             |
| `name`            | string  | truncated message | Display name shown in the app and session tree.                                                                                                    |
| `model`           | string  | inherited         | Model override (e.g. `anthropic/claude-sonnet-4-6`). Omit to inherit from parent.                                                                  |
| `thinking`        | string  | inherited         | Thinking level: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`.                                                                                |
| `detached`        | boolean | `false`           | If true, creates an independent session with no parent-child link. Gets full capabilities including its own `spawn_agent`. Monitored from the app. |
| `wait`            | boolean | `false`           | If true, blocks until the child finishes and returns its final response inline.                                                                    |
| `timeout_seconds` | number  | 1800              | Max seconds to wait (only when `wait=true`).                                                                                                       |

**Fire-and-forget** (default): returns immediately with the child's session ID. When the child finishes, the parent gets a `subagent_result` message containing status, cost, changed files, and the child's last response. If the parent is idle, the result is appended without triggering a turn. If the parent is busy, the result is queued as a follow-up so it does not interrupt the current turn.

**Wait mode** (`wait=true`): blocks the parent's context until the child reaches a terminal state. Returns the child's last response, cost, changed files, and duration. Use for sequential dependencies where the parent needs the result before continuing.

### inspect_agent

Progressive-disclosure trace inspection. Three levels of detail:

1. **Overview** (`inspect_agent(id)`) — turn count, tool breakdown, error markers, changed files. Start here.
2. **Turn detail** (`inspect_agent(id, turn: N)`) — tool list with condensed args and error previews for a specific turn.
3. **Tool detail** (`inspect_agent(id, turn: N, tool: M)`) — full tool arguments and output.

Set `response: true` to get the full assistant response text (no truncation). Combine with `turn` to get a specific turn's response.

Works on both active and stopped sessions — the trace is read from the session's JSONL file.

### send_message

Send a message to another session in the workspace.

| Parameter  | Type                      | Default   | Description                             |
| ---------- | ------------------------- | --------- | --------------------------------------- |
| `id`       | string                    | required  | Target session ID.                      |
| `message`  | string                    | required  | Message content.                        |
| `behavior` | `"steer"` \| `"followUp"` | `"steer"` | How to deliver when the target is busy. |

Delivery depends on the target's state:

- **Idle**: starts a new turn (prompt).
- **Busy + steer**: injected after current tool calls finish, before the next LLM call. Use for course corrections.
- **Busy + followUp**: queued until the current turn finishes. Use for "do this next."
- **Stopped**: the session is automatically resumed and the message is delivered as a new prompt. Resuming within ~5 minutes of the child stopping benefits from prompt cache hits.

An agent-origin preamble (`[From agent "Name" (id)]`) is prepended so the recipient knows the source.

### stop_agent

Stop a running child session. Only works on sessions in the caller's spawn tree (not workspace-wide).

| Parameter | Type   | Description         |
| --------- | ------ | ------------------- |
| `id`      | string | Session ID to stop. |

## Spawn tree

Sessions form a tree: each child tracks its `parentSessionId`. The tree has a configurable max depth (default: 1 — children cannot spawn their own children). Set `subagents.maxDepth` to allow deeper trees, or use `detached: true` for independent sessions that bypass the tree entirely with full spawn capability.

The iOS app renders the spawn tree with a collapsible status bar showing each child's state, cost, and duration. The parent session's cost aggregates the full tree.

## Visibility model

A parent waiting on a child (via `wait=true`) receives aggregate progress updates — status, message count, cost, and elapsed time. It does **not** receive individual tool calls, streaming text, or tool output from the child. This is intentional: the parent's context window is expensive, and flooding it with every `bash` and `read` from a child would be wasteful.

Progress updates are event-driven. The server's internal subscribe mechanism delivers `state` messages at turn-level boundaries such as agent start, agent end, and message end. Child completion hooks and `wait=true` both rely on those lifecycle events rather than sleep loops or polling.

To inspect a child's detailed execution, use `inspect_agent` after the fact — it reads the child's JSONL trace file and provides progressive disclosure from overview down to individual tool output.

## Lifecycle configuration

All subagent lifecycle behavior is configurable via `config.extensions.subagents`:

```json
{
  "extensions": {
    "subagents": {
      "maxDepth": 1,
      "autoStopWhenDone": false,
      "startupGraceMs": 60000,
      "defaultWaitTimeoutMs": 1800000,
      "modelPolicy": {
        "approvedModels": ["openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5"],
        "defaultModel": "openai-codex/gpt-5.5",
        "defaultThinking": "medium",
        "profiles": {
          "discovery": {
            "description": "Fast repo and web discovery.",
            "model": "openai-codex/gpt-5.4-mini",
            "thinking": "minimal",
            "guidelines": [
              "Prefer search and inspection before edits.",
              "Stay cheap and fast unless evidence says otherwise."
            ]
          }
        }
      }
    }
  }
}
```

| Field                         | Default   | Description                                                                                                                                                                                |
| ----------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `maxDepth`                    | `1`       | How many levels deep agents can spawn. `1` = parent-child only. `2` = allows grandchildren. `0` = spawning disabled.                                                                       |
| `autoStopWhenDone`            | `false`   | Whether children automatically stop after completing their work. When `false`, children stay alive for follow-up messages via `send_message`.                                              |
| `startupGraceMs`              | `60000`   | How long (ms) to wait for a child to start producing output before killing it. Covers VM boot, model loading, and first LLM response. Increase for sandbox environments with slow startup. |
| `defaultWaitTimeoutMs`        | `1800000` | Default timeout (ms) for `spawn_agent(wait=true)` when the caller doesn't specify `timeout_seconds`.                                                                                       |
| `modelPolicy.approvedModels`  | none      | Optional allowlist for subagent model IDs. If set, `spawn_agent` rejects anything outside this list.                                                                                       |
| `modelPolicy.defaultModel`    | none      | Default model for subagents when the caller omits `model`. Useful for steering work toward `openai-codex/*` variants.                                                                      |
| `modelPolicy.defaultThinking` | none      | Default thinking level when the caller omits `thinking`.                                                                                                                                   |
| `modelPolicy.profiles.*`      | none      | Named presets such as `discovery`, `coding`, or `review`. Each profile can set `model`, `thinking`, and extra prompt `guidelines`.                                                         |

`spawn_agent` now also accepts an optional `profile` parameter. Profiles are a clean way to standardize lanes like discovery, code search, web research, and deep implementation work without hard-coding model choices into prompts.

Set via CLI: `oppi config set extensions '{"subagents":{"modelPolicy":{"defaultModel":"openai-codex/gpt-5.5"}}}'`. Partial updates merge with defaults.

## Git safety

All agents in a workspace share the same working directory. For tasks that touch different files, parallel spawning is safe. For larger changes that overlap, run agents sequentially or use git worktrees.

## Workspace configuration

`subagents` and `ask` are enabled by default.

If a workspace sets `extensions`, that field becomes an authoritative allowlist for optional extensions. Omitting `subagents` or `ask` disables them for that workspace.
