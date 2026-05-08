# Permission gate policy (plain guide)

This guide explains how the server decides whether a tool call is allowed, blocked, or sent to your phone for approval.

## What it does

For each tool call, the gate can:

- **allow** it
- **ask** you on phone
- **block/deny** it

The runtime decision comes from:

1. reserved server guards (`policy.*` tools and protected config/rules files always ask)
2. structural heuristics from `config.policy.heuristics`
3. your runtime rules (`~/.config/oppi/rules.json`), including defaults seeded from `config.policy.guardrails` and `config.policy.permissions`
4. default fallback from `config.policy.fallback` (`allow` by default)

`config.policy.guardrails` and `config.policy.permissions` are not a separate live policy layer. They seed missing entries into `rules.json`; after that, `rules.json` is the rule source of truth.

## How approval works on your phone

When a tool call gets `ask`, Oppi sends a push notification to your phone. The notification opens a sheet showing the tool name and its arguments. You choose:

- **Allow** — runs this call once
- **Deny** — blocks it and tells the agent

When you allow, you also pick a scope:

- **Once** — allows only this exact call
- **This session** — allows matching calls for the rest of the current session
- **Always** — creates a persistent rule (saved to `rules.json`) that applies to future sessions

Deny supports **once** and **always**. A requested deny-this-session scope is normalized to deny-once.

The server learns from your choice. A "this session" allow creates a temporary rule scoped to the current session ID. An "always" allow or deny writes a permanent rule to `~/.config/oppi/rules.json`. Future matching calls skip the prompt entirely.

If you don't respond, the call is held until `approvalTimeoutMs` elapses, then blocked.

## Default mode (YOLO-ish)

Out of the box, the gate is on with `fallback: "allow"`:

```json
{
  "permissionGate": true,
  "policy": { "fallback": "allow" }
}
```

Most tool calls auto-run. Seeded rules and built-in heuristics still catch dangerous patterns such as credential exfiltration, pipe-to-shell, privileged commands, external publishes, and protected config/rules edits. Use at your own risk — it's what I do.

If `permissionGate` is `false`, the approval gate is bypassed entirely.

## Simple rules example

Runtime rules live in `~/.config/oppi/rules.json`. Defaults from `config.policy.guardrails` and `config.policy.permissions` are seeded here when missing, and phone approvals with "Always" are persisted here.

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
- For non-deny matches, the most specific matching rule wins.
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

To require approval for everything that isn't explicitly allowed by `rules.json` or caught by a stricter heuristic, set the policy fallback:

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
