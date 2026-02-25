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
  "runtimePathEntries": ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"],
  "runtimeEnv": {
    "EDITOR": "nvim"
  },
  "tls": {
    "mode": "disabled",
    "certPath": "~/.config/oppi/tls/self-signed/server.crt",
    "keyPath": "~/.config/oppi/tls/self-signed/server.key",
    "caPath": "~/.config/oppi/tls/self-signed/ca.crt"
  },
  "thinkingLevelByModel": {}
}
```

| Key                       | Type     | Default                      | Description                                                                                       |
| ------------------------- | -------- | ---------------------------- | ------------------------------------------------------------------------------------------------- |
| `port`                    | number   | `7749`                       | HTTP + WebSocket port                                                                             |
| `host`                    | string   | `0.0.0.0`                    | Bind address |
| `dataDir`                 | string   | `~/.config/oppi`             | State directory                                                                                   |
| `defaultModel`            | string   | `openai-codex/gpt-5.3-codex` | Default model for new sessions                                                                    |
| `sessionIdleTimeoutMs`    | number   | `600000`                     | Kill idle sessions after 10 min                                                                   |
| `workspaceIdleTimeoutMs`  | number   | `1800000`                    | Stop idle workspaces after 30 min                                                                 |
| `maxSessionsPerWorkspace` | number   | `3`                          | Max concurrent sessions per workspace                                                             |
| `maxSessionsGlobal`       | number   | `5`                          | Max concurrent sessions total                                                                     |
| `approvalTimeoutMs`       | number   | `120000`                     | Permission gate timeout; `0` = no expiry                                                          |
| `permissionGate`          | boolean  | `true`                       | Gate on with `fallback: allow` — heuristics catch dangerous ops, everything else auto-runs        |
| `runtimePathEntries`      | string[] | sane executable paths        | Runtime PATH entries used by tools (explicit, config-driven)                                      |
| `runtimeEnv`              | object   | `{}`                         | Additional runtime env vars (string values)                                                       |
| `tls.mode`                | string   | `"disabled"`                | Transport mode: `disabled`, `self-signed`, `tailscale`, or `manual` (future: `auto`, `cloudflare`) |
| `tls.certPath`            | string   | self-signed default path     | PEM cert path used for HTTPS/WSS (`manual` requires explicit path)                                 |
| `tls.keyPath`             | string   | self-signed default path     | PEM private key path used for HTTPS/WSS (`manual` requires explicit path)                          |
| `tls.caPath`              | string   | self-signed default path     | Optional CA chain path (required in `self-signed` mode for client pinning)                         |
| `thinkingLevelByModel`    | object   | `{}`                         | Per-model thinking level (e.g. `"high"`)                                                          |

Auth tokens (`token`, `authDeviceTokens`, `pairingToken`) are managed by `oppi pair` and `oppi token rotate`. Don't edit manually.

For local HTTPS/WSS in a container or LAN setup, set:

```bash
oppi config set tls '{"mode":"self-signed"}'
```

`oppi serve`/`oppi pair` will auto-generate cert material under `~/.config/oppi/tls/self-signed/`.

For Tailscale HTTPS/WSS on a host with Tailscale installed, set:

```bash
oppi config set tls '{"mode":"tailscale"}'
```

In `tailscale` mode, `oppi serve`/`oppi pair` requests/renews certs via `tailscale cert` into `~/.config/oppi/tls/tailscale/` by default.

Prerequisites:
- MagicDNS enabled in the tailnet
- HTTPS certificates enabled in the tailnet DNS settings
- `tailscale` CLI connected on the host (`tailscale status`)

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
