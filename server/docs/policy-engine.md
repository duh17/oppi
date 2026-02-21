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
3. default fallback (`ask`)

## Recommended mode (default)

Keep this in `~/.config/oppi/config.json`:

```json
{
  "permissionGate": true
}
```

This is the safe default for daily use.

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

## YOLO mode (not recommended)

If you want zero prompts, disable the gate:

```json
{
  "permissionGate": false
}
```

This effectively allows everything the model asks to run.

Use only if you accept the risk.

## Audit log

Decisions are written to:

- `~/.config/oppi/audit.jsonl`

Useful for understanding what was auto-allowed vs asked vs blocked.

## Related docs

- `server/docs/config-schema.md`
