# Permission Gate

The permission gate intercepts tool calls from pi and decides whether to allow them, ask your phone, or deny them. It's **best-effort** — it pattern-matches on tool names and arguments. A determined model can get around it.

For real isolation, run sessions in a container workspace.

To disable the gate entirely, set `"permissionGate": false` in `config.json`. All tool calls will auto-allow.

## How it works

The permission-gate extension runs inside pi and hooks every `tool_call` event. It asks the oppi-server over a localhost TCP socket before the tool executes. The server evaluates the request through a 4-layer pipeline and either allows, denies, or forwards it to your phone for approval.

## Evaluation pipeline

Every tool call runs through these layers in order. First non-null result wins:

```
1. Reserved guards     policy.* tools → always ask (human approval for policy changes)
2. Heuristics          structural detection (data egress, pipe-to-shell, secret access, ...)
3. User rules          glob-based matching, deny wins, most specific rule wins
4. Default             → ask
```

### Heuristics

General-purpose detection logic that can't be expressed as glob patterns. Configurable on/off in server config:

| Heuristic | What it catches | Default |
|-----------|-----------------|---------|
| `pipeToShell` | `\| sh`, `\| bash` — arbitrary code execution | ask |
| `dataEgress` | `curl -d`, `wget --post-data` — outbound data transfer | ask |
| `secretEnvInUrl` | `$API_KEY` in curl URLs — credential leakage | ask |
| `secretFileAccess` | Reads of `~/.ssh/`, `~/.aws/`, `.env` files | deny |

These are tool-agnostic structural detectors. Skill-specific behavior (e.g. browser navigation) should be handled by rules, not hardcoded heuristics.

### User rules

All rules are evaluated together. Deny always wins. Among non-deny matches, the most specific rule wins (longer literal prefix in the glob pattern). Ties go to `ask` over `allow`.

## Rules

One model for everything — presets, learned rules, manual rules:

```json
{
  "id": "abc123",
  "tool": "bash",
  "decision": "deny",
  "pattern": "git push*",
  "executable": "git",
  "label": "Block git push",
  "scope": "global",
  "source": "preset",
  "createdAt": 1708300000000
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique identifier |
| `tool` | yes | `read`, `write`, `edit`, `bash`, or any extension tool |
| `decision` | yes | `allow`, `ask`, or `deny` |
| `pattern` | no | Glob pattern — matches path (file tools) or command (bash) |
| `executable` | no | Bash shortcut — matches parsed executable name |
| `label` | no | Human-readable description |
| `scope` | yes | `session`, `workspace`, or `global` |
| `sessionId` | if session | Session this rule applies to |
| `workspaceId` | if workspace | Workspace this rule applies to |
| `expiresAt` | no | Epoch ms — rule ignored after this time |
| `source` | no | `preset`, `learned`, or `manual` |
| `createdAt` | no | Epoch ms |

### Matching

- **File tools** (`read`, `write`, `edit`): `pattern` is a glob matched against the canonical absolute path
- **Bash**: `pattern` is a glob matched against the full command string. `executable` matches the parsed executable name. If both are set, both must match.
- **Unknown tools** with no matching rule: default to `ask`

### Specificity

When multiple non-deny rules match, the most specific wins:

1. Longer literal prefix in the glob (everything before the first `*`, `?`, `[`, `{`)
2. `executable` + `pattern` beats `pattern`-only beats `executable`-only
3. `ask` beats `allow` on tie

### Scope

- **session**: in-memory, dies when the session ends
- **workspace**: persisted, active for any session in that workspace
- **global**: persisted, active everywhere

## Default presets

Shipped on first run. You can edit or delete any of these.

### Safety presets (global)

| Tool | Pattern | Decision | Label |
|------|---------|----------|-------|
| bash | *(executable: sudo)* | deny | Block sudo |
| bash | `*auth.json*` | deny | Protect API keys |
| bash | `*printenv*_KEY*` | deny | Protect env secrets |
| bash | `*printenv*_TOKEN*` | deny | Protect env tokens |
| read | `**/.ssh/id_*` | deny | Protect SSH keys |
| bash | `*:(){ :\|:& };*` | deny | Block fork bomb |
| bash | `git push*` *(executable: git)* | ask | Git push |
| bash | `rm *-*r*` *(executable: rm)* | ask | Recursive delete |
| bash | *(executable: ssh)* | ask | SSH connection |

These are best-effort convenience patterns. The heuristics layer handles the genuinely dangerous cases with structural detection.

### Workspace presets (on create)

Each new workspace auto-creates allow rules for its root directory:

```
read   /workspace/foo/**   allow
write  /workspace/foo/**   allow
edit   /workspace/foo/**   allow
```

## Approving from your phone

When the gate asks your phone, you see fixed buttons:

| Button | Creates rule? | Scope |
|--------|---------------|-------|
| Allow Once | No | — |
| Allow Session | Yes (in-memory) | session |
| Allow Always | Yes (persisted) | workspace |
| Deny | No | — |
| Deny Always | Yes (persisted) | workspace |

For policy changes (`policy.*` tools), only **Approve** / **Reject** are shown. Policy approvals never create learned rules — always one-shot.

The protocol supports `global` scope decisions, but the iOS UI currently exposes workspace-scoped “always” actions.

## Path handling

File tool paths are normalized before matching:

1. Expand `~` → home directory
2. Resolve to absolute path
3. Collapse `..` and duplicate `/`
4. Best-effort symlink resolution

Rules are stored with fully expanded paths. Deny checks run against both the raw normalized path and the symlink-resolved path to prevent bypass.

## Policy changes

Policy mutations (adding, editing, or deleting rules) are treated as `policy.*` tool calls. The engine hardcodes `policy.*` → always `ask`, so every policy change requires your explicit approval on the phone. No exceptions, no auto-apply.

## Rules file

All rules: `~/.config/oppi/rules.json`

```json
[
  {
    "id": "abc123",
    "tool": "bash",
    "decision": "ask",
    "executable": "git",
    "pattern": "git push*",
    "label": "Git push",
    "scope": "global",
    "source": "preset",
    "createdAt": 1708300000000
  }
]
```

You can edit this file directly. Session-scoped rules are in-memory only and don't appear here.

## Audit log

Every decision is logged to `~/.config/oppi/audit.jsonl` (append-only).

## Source files

| File | What |
|------|------|
| `src/policy.ts` | Evaluator, heuristics, bash parsing, presets |
| `src/rules.ts` | Unified rule store (persisted + session memory) |
| `src/gate.ts` | TCP gate server + approval lifecycle |
| `src/audit.ts` | Audit log |
| `src/routes.ts` | Policy/rule HTTP endpoints |
| `extensions/permission-gate/` | Pi extension |
