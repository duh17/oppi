---
name: agent-sessions
description: Unified Oppi session lifecycle skill. This skill should be used when dispatching subagents, checking session status, reading events/messages/trace output, stopping sessions, or running review + optional review dispatch from one CLI.
---

# Agent Sessions

Manage Oppi agent sessions with one entry point.

Run the CLI:

```bash
node {baseDir}/scripts/agent-sessions.mjs <command> [flags]
```

## Quick Reference

| Command | Purpose | Example |
|---|---|---|
| `list` | List recent sessions (workspace or all) | `node {baseDir}/scripts/agent-sessions.mjs list --workspace oppi --limit 20` |
| `status <id>` | Get session detail/status | `node {baseDir}/scripts/agent-sessions.mjs status abc123 --workspace oppi` |
| `latest` | Get most recent session detail | `node {baseDir}/scripts/agent-sessions.mjs latest --workspace oppi` |
| `dispatch` | Create, resume, and prompt a session via WebSocket | `node {baseDir}/scripts/agent-sessions.mjs dispatch --workspace oppi --prompt '...' --model openai-codex/gpt-5.3-codex --thinking high` |
| `stop <id>` | Stop a running session | `node {baseDir}/scripts/agent-sessions.mjs stop abc123 --workspace oppi` |
| `events <id>` | Fetch catch-up events (`since` cursor supported) | `node {baseDir}/scripts/agent-sessions.mjs events abc123 --workspace oppi --since 0` |
| `messages <id>` | Extract final assistant text from full trace context | `node {baseDir}/scripts/agent-sessions.mjs messages abc123 --workspace oppi` |
| `trace <id>` | Return JSONL trace path (or content with `--jsonl`) | `node {baseDir}/scripts/agent-sessions.mjs trace abc123 --workspace oppi` |
| `review` | Run `server/scripts/ai-review.mjs`; optionally dispatch AI review | `node {baseDir}/scripts/agent-sessions.mjs review --staged --dispatch` |

## Output Contract

Return JSON by default (compact, agent-friendly).

Use `--human` for pretty-printed JSON.

## Dispatch Flags

| Flag | Meaning |
|---|---|
| `--workspace <name|id>` | Required workspace target |
| `--prompt '...'` | Required prompt payload |
| `--name` | Optional session name |
| `--model` | Optional model override |
| `--thinking` | Optional thinking level (`off|minimal|low|medium|high|xhigh`) |
| `--todo` | Inject TODO markdown context (fail-fast if explicit TODO missing) |
| `--context-file` | Inject file content context (repeatable) |

Dispatch flow:
1. Resolve workspace.
2. Create session (`POST /workspaces/:id/sessions`).
3. Resume session (`POST /resume`).
4. Open WebSocket `/stream`, subscribe, send prompt.

## Model Selection (Brief)

| Task type | Model | Thinking |
|---|---|---|
| Architecture / deep review | `openai-codex/gpt-5.3-codex` | `xhigh` |
| Standard implementation | `openai-codex/gpt-5.3-codex` or `anthropic/claude-sonnet-4-6` | `medium` |
| Mechanical/refactor | `openai-codex/gpt-5.3-codex-spark` or sonnet | `low` |

Load detailed guidance from:
- `{baseDir}/references/model-selection.md`

## Review Workflow

Run mechanical review first:

```bash
node {baseDir}/scripts/agent-sessions.mjs review --staged
# or
node {baseDir}/scripts/agent-sessions.mjs review --commits 3
```

Dispatch review session when checks warn/fail:

```bash
node {baseDir}/scripts/agent-sessions.mjs review --staged --dispatch
```

Review integration behavior:
- Resolve repo root via `git rev-parse --show-toplevel`.
- Run `<repo-root>/server/scripts/ai-review.mjs`.
- Parse summary + prompt.
- Optionally dispatch `ai-review` session with codex/high.

## Requirements

- Oppi server running at `https://localhost:7749`
- Self-signed TLS accepted (verification skipped by script)
- `~/.config/oppi/config.json` with `token`
- `ws` module available (resolved from server `node_modules` if needed)
