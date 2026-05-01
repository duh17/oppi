# Sub-agents

Oppi's `subagents` extension lets an agent create and manage child sessions inside the same workspace. Use it when one session should delegate a task, wait for a result, or inspect another session's trace.

## Enabling the extension

`subagents` is a first-party Oppi extension name. It is not enabled automatically.

To use it in a workspace, include `subagents` in that workspace's `extensions` list.

If a workspace sets `extensions`, that list is authoritative. Omitting `subagents` disables it.

## Tool surface

Root sessions get four tools:

- `spawn_agent`
- `inspect_agent`
- `send_message`
- `stop_agent`

Child sessions get the non-spawning subset only:

- `inspect_agent`
- `send_message`

## spawn_agent

Create a new session in the current workspace.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `message` | string | required | Task prompt for the child. Include the context it needs because the child does not see the parent's conversation. |
| `name` | string | truncated message | Display name shown in the app and session tree. |
| `profile` | string | none | Optional named preset from `config.extensions.subagents.modelPolicy.profiles`. |
| `model` | string | inherited | Model override for the child session. |
| `thinking` | string | inherited | Thinking level override: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. |
| `detached` | boolean | `false` | Create an independent session with no parent-child link. Detached sessions can spawn their own children. |
| `wait` | boolean | `false` | Block until the child finishes its current task and return the result inline. |
| `timeout_seconds` | number | `1800` | Maximum wait time when `wait=true`. |

### Fire-and-forget mode

By default, `spawn_agent` returns immediately with the child session ID.

When the child finishes, the parent receives a `subagent_result` message with:

- final status
- cost
- changed files summary
- the child's last response

If the parent is idle, Oppi appends that result without starting a new turn. If the parent is busy, Oppi queues it as a follow-up.

### Wait mode

With `wait=true`, the parent blocks until the child finishes its current task. Oppi then stops that child immediately and returns the result inline.

Use wait mode for sequential dependencies, not for long-running background work.

## inspect_agent

`inspect_agent` reads a session's JSONL trace and returns progressively more detail.

Levels:

1. **Overview**: `inspect_agent(id)`
2. **Turn detail**: `inspect_agent(id, turn: N)`
3. **Tool detail**: `inspect_agent(id, turn: N, tool: M)`

Set `response: true` to return the full assistant response text instead of the summarized trace view.

Works for both active and stopped sessions.

## send_message

Send a message to another session in the same workspace.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `id` | string | required | Target session ID. |
| `message` | string | required | Message content. |
| `behavior` | `"steer" \| "followUp"` | `"steer"` | Delivery mode when the target is busy. |

Delivery rules:

- **Idle**: starts a new turn
- **Busy + `steer`**: injected after current tool calls, before the next model call
- **Busy + `followUp`**: queued after the current turn finishes
- **Stopped**: automatically resumed, then delivered as a new prompt

Oppi prepends an origin marker such as `[From agent "Name" (id)]` so the recipient knows where the message came from.

Prefer `send_message` over spawning a new child when an earlier subagent already investigated the same area.

## stop_agent

Stop a running child session.

This only works for sessions in the caller's spawn tree. It is not a workspace-wide kill switch.

| Parameter | Type | Description |
| --- | --- | --- |
| `id` | string | Session ID to stop. |

## Spawn tree and detached sessions

Each normal child session records `parentSessionId`, so sessions form a tree.

Defaults:

- `maxDepth = 1`
- a child cannot spawn grandchildren unless you raise that limit

If you need a fully independent session, use `detached: true`. Detached sessions are outside the spawn tree and keep full spawn capability.

## Visibility model

A parent waiting on a child receives coarse progress updates only:

- status
- message count
- cost
- elapsed time

It does **not** receive the child's tool calls, streaming text, or full tool output.

This is deliberate. The detailed execution history stays in the child's own trace file and is available later through `inspect_agent`.

In wait mode, Oppi treats a child returning to `ready` after producing new output as completion and stops it immediately.

## Configuration

Configure subagents under `config.extensions.subagents`.

```json
{
  "extensions": {
    "subagents": {
      "maxDepth": 1,
      "defaultWaitTimeoutMs": 1800000,
      "modelPolicy": {
        "defaultModel": "openai-codex/gpt-5.4",
        "defaultThinking": "medium",
        "profiles": {
          "planning": {
            "description": "High-quality planning and architecture analysis before implementation.",
            "model": "openai-codex/gpt-5.5",
            "thinking": "high",
            "guidelines": [
              "Do not edit files unless explicitly asked; produce concrete plans with file paths and validation steps.",
              "Prefer reading existing code and tests before proposing new abstractions."
            ]
          },
          "review": {
            "description": "Careful code review, risk analysis, and regression hunting.",
            "model": "openai-codex/gpt-5.5",
            "thinking": "high",
            "guidelines": [
              "Review evidence from diffs, tests, and relevant source files before giving conclusions.",
              "Prioritize correctness, security, data loss, concurrency, and protocol drift over style nits.",
              "Return findings with severity, confidence, file paths, and concrete fixes."
            ]
          },
          "coding": {
            "description": "Implementation work in the repo with the codex coding model.",
            "model": "openai-codex/gpt-5.3-codex",
            "thinking": "medium",
            "guidelines": [
              "Make focused code changes and validate them with the narrowest reliable checks.",
              "Follow project AGENTS.md rules and avoid touching unrelated files."
            ]
          },
          "research": {
            "description": "Codebase discovery, documentation lookup, web research, and concise synthesis.",
            "model": "openai-codex/gpt-5.4",
            "thinking": "medium",
            "guidelines": [
              "Search broadly first, then read primary sources, documentation, or source files before summarizing.",
              "Prefer targeted reads over exhaustive scanning; note uncertainty clearly.",
              "Return structured handoff context with links or file paths, relevant symbols, risks, and where to start."
            ]
          }
        }
      }
    }
  }
}
```

### Active configuration fields

These settings currently affect runtime behavior:

| Field | Default | What it does |
| --- | --- | --- |
| `maxDepth` | `1` | Maximum spawn depth for non-detached sessions. `0` disables spawning. |
| `defaultWaitTimeoutMs` | `1800000` | Default timeout for `spawn_agent(wait=true)` when `timeout_seconds` is omitted. |
| `modelPolicy.approvedModels` | none | Optional allowlist for subagent model IDs. |
| `modelPolicy.defaultModel` | none | Default model when the caller omits `model`. |
| `modelPolicy.defaultThinking` | none | Default thinking level when the caller omits `thinking`. |
| `modelPolicy.profiles.*` | none | Named presets that can set `model`, `thinking`, and prompt `guidelines`. |

### Accepted but not currently enforced

The config type also accepts these fields:

- `autoStopWhenDone`
- `childIdleTimeoutMs`
- `startupGraceMs`

They are reserved for future lifecycle controls, but they do not currently change runtime behavior.

Use `profile` on `spawn_agent` to select a named preset such as `research`, `coding`, or `review`.

Examples:

```ts
spawn_agent({
  profile: "research",
  message: "Find the files that implement session queue replay. Do not edit files."
})

spawn_agent({
  profile: "coding",
  message: "Implement the focused fix from this plan and run the narrowest relevant checks."
})

spawn_agent({
  profile: "review",
  message: "Review the current diff for correctness, regressions, and missing tests."
})
```

### Profile prompt style

Profiles follow the same spirit as Amp's subagent prompts: keep the main thread clean by delegating bounded work into isolated context windows.

Good profile prompts are:

- **Role-specific**: research gathers context and sources, coding changes files, review looks for risk.
- **Explicit about scope**: include file areas, allowed edits, and what not to touch.
- **Output-shaped**: ask for file paths, links, findings, validation steps, or a handoff summary.
- **Cost-aware**: use stronger models for planning/review and faster coding/research models for focused work.
- **Not magical**: profiles currently set `model`, `thinking`, and prompt guidelines. They do not enforce tool permissions; include read-only or no-edit instructions in the task until tool restrictions exist.

Recommended defaults:

| Profile | Model | Thinking | Use for |
| --- | --- | --- | --- |
| `planning` | `openai-codex/gpt-5.5` | `high` | Architecture plans and complex tradeoffs. |
| `review` | `openai-codex/gpt-5.5` | `high` | Code review, regression hunting, risk analysis. |
| `coding` | `openai-codex/gpt-5.3-codex` | `medium` | Focused implementation work. |
| `research` | `openai-codex/gpt-5.4` | `medium` | Codebase discovery, documentation lookup, and source-backed web research. |

## Git safety

All sessions in a workspace share the same working directory.

Parallel spawning is fine when tasks touch different files. If multiple sessions may edit the same area, run them sequentially or use separate git worktrees.
