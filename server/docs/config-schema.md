# Server Config Schema (`config.json`) — v3

This document describes the **current** config shape used by `oppi-server`.

Canonical security/pairing behavior is defined in:
- `docs/security-pairing-spec-v3.md`

Config file location:
- `~/.config/oppi/config.json` (default)
- or `$OPPI_DATA_DIR/config.json`

Current schema version: **3**

---

## Top-level shape (current)

```json
{
  "configVersion": 3,
  "port": 7749,
  "host": "0.0.0.0",
  "dataDir": "~/.config/oppi",
  "defaultModel": "anthropic/claude-sonnet-4-20250514",
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000,
  "maxSessionsPerWorkspace": 3,
  "maxSessionsGlobal": 5,
  "approvalTimeoutMs": 120000,

  "allowedCidrs": [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10"
  ],

  "token": "sk_...",
  "pairingToken": "pt_...",
  "pairingTokenExpiresAt": 1760000000000,
  "authDeviceTokens": ["dt_..."],
  "pushDeviceTokens": ["...apns..."],
  "liveActivityToken": "...",

  "thinkingLevelByModel": {
    "openai-codex/gpt-5.3-codex": "high"
  }
}
```

---

## Field reference

| Key | Type | Default | Notes |
|---|---|---:|---|
| `configVersion` | number | `3` | Internal schema version |
| `port` | number | `7749` | HTTP + WS port |
| `host` | string | `"0.0.0.0"` | Bind address |
| `dataDir` | string | `~/.config/oppi` | State root |
| `defaultModel` | string | `"anthropic/claude-sonnet-4-20250514"` | Default model |
| `sessionIdleTimeoutMs` | number | `600000` | Session idle timeout |
| `workspaceIdleTimeoutMs` | number | `1800000` | Workspace idle timeout |
| `maxSessionsPerWorkspace` | number | `3` | Per-workspace session cap |
| `maxSessionsGlobal` | number | `5` | Global session cap |
| `approvalTimeoutMs` | number | `120000` | Permission timeout; `0` disables expiry |
| `allowedCidrs` | string[] | private ranges + loopback | Source IP allowlist for HTTP + WS |
| `policy` | object? | built-in balanced policy | Declarative policy config (`fallback`, `guardrails`, `permissions`) |
| `token` | string? | unset | Owner/admin bearer token (`sk_...`) |
| `pairingToken` | string? | unset | One-time pairing token (`pt_...`) |
| `pairingTokenExpiresAt` | number? | unset | Pairing token expiry epoch ms |
| `authDeviceTokens` | string[]? | `[]` | Auth device tokens (`dt_...`) |
| `pushDeviceTokens` | string[]? | `[]` | APNs push tokens (non-auth) |
| `liveActivityToken` | string? | unset | APNs live activity token (non-auth) |
| `thinkingLevelByModel` | object? | `{}` | Per-model thinking preference map |

---

## Policy config (`policy`)

`policy` follows the safety-mode schema shape in `server/config/schemas/safety-mode.schema.json`:

```json
{
  "schemaVersion": 1,
  "mode": "balanced",
  "fallback": "ask",
  "guardrails": [
    {
      "id": "block-secret-files",
      "decision": "block",
      "immutable": true,
      "match": { "tool": "read", "pathMatches": "*identity_ed25519*" }
    }
  ],
  "permissions": [
    {
      "id": "ask-git-push",
      "decision": "ask",
      "match": { "tool": "bash", "executable": "git", "commandMatches": "git push*" }
    }
  ]
}
```

Notes:
- `decision` values are `allow | ask | block`.
- In strict validation mode, unknown keys under `policy`, permission entries, and match objects are rejected.
- This config is now parsed/validated by server config normalization and is the migration target for TODO-93a31067 policy engine wiring.

## Security-critical semantics

- API/WS auth accepts only:
  - owner token (`sk_...`) and
  - auth device tokens (`dt_...`)
- Push tokens (`pushDeviceTokens`, `liveActivityToken`) are **never** accepted for API auth.
- `allowedCidrs` is enforced for both HTTP requests and WebSocket upgrades.
- Startup fails fast for non-loopback bind without a configured auth token.

---

## Compatibility + migration behavior

Legacy config blocks are accepted during normalization for rollback safety, then removed on rewrite:

- `security.allowedCidrs` → migrated to top-level `allowedCidrs` (if top-level missing)
- `security.allowedCidrs` ignored when top-level `allowedCidrs` already exists
- `invite` ignored (deprecated)
- `identity` ignored (deprecated)
- legacy `deviceTokens` are migrated to `pushDeviceTokens` only (never auth)

Expected warnings include:
- `config.security.allowedCidrs is deprecated; migrated to config.allowedCidrs.`
- `config.security.allowedCidrs is deprecated and ignored in favor of config.allowedCidrs.`
- `config.invite is deprecated and ignored.`
- `config.identity is deprecated and ignored.`
- `config.deviceTokens is deprecated; migrated to config.pushDeviceTokens (not used for API auth).`

---

## Validation

```bash
cd server
npx oppi config validate
```

This validates field types, enum/range constraints, unknown keys, and CIDR syntax.
