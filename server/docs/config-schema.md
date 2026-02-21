# Config Schema

Config file: `~/.config/oppi/config.json` (or `$OPPI_DATA_DIR/config.json`)

Auto-created on first `npx oppi serve`, or manually via `npx oppi init`.

## Fields

```json
{
  "port": 7749,
  "host": "0.0.0.0",
  "dataDir": "~/.config/oppi",
  "defaultModel": "openai-codex/gpt-5.3-codex",
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000,
  "maxSessionsPerWorkspace": 3,
  "maxSessionsGlobal": 5,
  "approvalTimeoutMs": 120000,
  "permissionGate": true,
  "allowedCidrs": [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10"
  ],
  "thinkingLevelByModel": {}
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `port` | number | `7749` | HTTP + WebSocket port |
| `host` | string | `0.0.0.0` | Bind address (all interfaces — needed for phone access; `allowedCidrs` restricts who can connect) |
| `dataDir` | string | `~/.config/oppi` | State directory |
| `defaultModel` | string | `openai-codex/gpt-5.3-codex` | Default model for new sessions |
| `sessionIdleTimeoutMs` | number | `600000` | Kill idle sessions after 10 min |
| `workspaceIdleTimeoutMs` | number | `1800000` | Stop idle workspaces after 30 min |
| `maxSessionsPerWorkspace` | number | `3` | Max concurrent sessions per workspace |
| `maxSessionsGlobal` | number | `5` | Max concurrent sessions total |
| `approvalTimeoutMs` | number | `120000` | Permission gate timeout; `0` = no expiry |
| `permissionGate` | boolean | `true` | Set to `false` to disable the permission gate entirely |
| `allowedCidrs` | string[] | private ranges | Source IP allowlist for HTTP + WS |
| `thinkingLevelByModel` | object | `{}` | Per-model thinking level (e.g. `"high"`) |

Auth tokens (`token`, `authDeviceTokens`, `pairingToken`) are managed by `oppi pair` and `oppi token rotate`. Don't edit manually.

## Policy rules

Rules live in `~/.config/oppi/rules.json` (not in `config.json`). Default presets are seeded on first run. See [policy-engine.md](policy-engine.md) for full details.

Heuristic settings (on/off toggles for structural detection) live under `policy.heuristics`:

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

Set any heuristic to `false` to disable it. Decisions: `allow`, `ask`, `block`.

## Validate

```bash
oppi config validate
```
