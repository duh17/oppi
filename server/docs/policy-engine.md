# Permission gate policy (plain guide)

This guide explains how the server decides whether a tool call is allowed, blocked, or sent to your phone for approval.

## What it does

For each tool call, the gate can:
- **allow** it
- **ask** you on phone
- **block/deny** it

The decision comes from:
1. built-in safety checks
2. your rules (`~/.config/oppi/rules.json`)
3. default fallback (`allow`)

## How approval works on your phone

When a tool call gets `ask`, Oppi sends a push notification to your phone. The notification opens a sheet showing the tool name and its arguments. You choose:

- **Allow** — runs this call once
- **Deny** — blocks it and tells the agent

When you approve, you also pick a scope:
- **Once** — allows only this exact call
- **This session** — allows matching calls for the rest of the current session
- **Always** — creates a persistent rule (saved to `rules.json`) that applies to future sessions

The server learns from your choice. A "this session" approval creates a temporary rule scoped to the current session ID. An "always" approval writes a permanent rule to `~/.config/oppi/rules.json`. Future matching calls skip the prompt entirely.

If you don't respond, the call is held until `approvalTimeoutMs` elapses, then blocked.

## Default mode (YOLO-ish)

Out of the box, the gate is on with `fallback: "allow"`:

```json
{
  "permissionGate": true
}
```

Most tool calls auto-run. Built-in heuristics still catch dangerous patterns (credential exfil, pipe-to-shell, sudo) and route those to your phone. Use at your own risk — it's what I do.

## Simple rules example

Rules live in `~/.config/oppi/rules.json`.

Example:

```json
[
  {
    "id": "allow-read-workspace",
    "tool": "read",
    "decision": "allow",
    "pattern": "/workspace/my-project/**",
    "scope": "workspace",
    "workspaceId": "my-project"
  },
  {
    "id": "ask-git-push",
    "tool": "bash",
    "decision": "ask",
    "executable": "git",
    "pattern": "git push*",
    "scope": "global"
  },
  {
    "id": "deny-ssh-keys",
    "tool": "read",
    "decision": "deny",
    "pattern": "**/.ssh/id_*",
    "scope": "global"
  }
]
```

Notes:
- `deny` wins over `allow` when multiple rules match.
- For bash rules, you can match by `executable`, `pattern`, or both.

## Heuristics (optional tuning)

You can tune built-in checks under `policy.heuristics` in config:

```json
{
  "policy": {
    "heuristics": {
      "pipeToShell": "ask",
      "dataEgress": "ask",
      "secretEnvInUrl": "ask",
      "secretFileAccess": "block"
    }
  }
}
```

Valid values: `"allow"`, `"ask"`, `"block"`, or `false` (disable that heuristic).

## Locking it down

To require approval for everything that isn't explicitly allowed by a rule, set the policy fallback:

```json
{
  "permissionGate": true,
  "policy": {
    "fallback": "ask"
  }
}
```

## Audit log

Decisions are written to:

- `~/.config/oppi/audit.jsonl`

Useful for understanding what was auto-allowed vs asked vs blocked.

## Related docs

- `server/docs/config-schema.md`
