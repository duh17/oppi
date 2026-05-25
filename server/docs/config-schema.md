# Config Schema

Oppi server uses a JSON config file with validated fields and sensible defaults.

| Location                     | Scope            |
| ---------------------------- | ---------------- |
| `~/.config/oppi/config.json` | Default data dir |
| `$OPPI_DATA_DIR/config.json` | Custom data dir  |

Auto-created on first `npx oppi serve`, or manually via `npx oppi init`. Validated on load — invalid fields fall back to defaults with warnings. New fields are backfilled automatically on startup.

## All Settings

Settings are listed in the order they appear in the config file. Auth state is documented separately — it lives in the same file but is managed by CLI commands, not edited by hand.

### Server

| Setting         | Type   | Default            | Description                                                                           |
| --------------- | ------ | ------------------ | ------------------------------------------------------------------------------------- |
| `configVersion` | number | `2`                | Schema version. Managed automatically — do not edit.                                  |
| `port`          | number | `7749`             | HTTP + WebSocket listen port. Range: 0-65535.                                         |
| `host`          | string | `"0.0.0.0"`        | Bind address. Use `"127.0.0.1"` to restrict to localhost.                             |
| `dataDir`       | string | `"~/.config/oppi"` | Root state directory. Contains sessions, workspaces, rules, config, and TLS material. |

### Model

Oppi does not define a top-level server default chat model. New chat sessions use the shared model-selection behavior documented in [`model-selection.md`](./model-selection.md): explicit model, inherited/source model, workspace `defaultModel`, then Pi settings.

Configure the machine-wide fallback in Pi settings, for example `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "xhigh"
}
```

Workspace defaults are stored on each workspace as `defaultModel` in canonical `"provider/model-id"` form.

### Session Lifecycle

| Setting                   | Type   | Default   | Description                                                                                   |
| ------------------------- | ------ | --------- | --------------------------------------------------------------------------------------------- |
| `sessionIdleTimeoutMs`    | number | `600000`  | Stop sessions after this many ms of inactivity. 600000 = 10 min. Min: 1.                      |
| `workspaceIdleTimeoutMs`  | number | `1800000` | Stop workspace runtimes after this many ms with no active sessions. 1800000 = 30 min. Min: 1. |
| `maxSessionsPerWorkspace` | number | `20`      | Max concurrent sessions in a single workspace. Min: 1.                                        |
| `maxSessionsGlobal`       | number | `40`      | Max concurrent sessions across all workspaces. Min: 1.                                        |

Use `sessionIdleTimeoutMs` in config files.

### Permission Gate

| Setting             | Type    | Default  | Description                                                                                                                              |
| ------------------- | ------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `approvalTimeoutMs` | number  | `120000` | How long the server waits for a user to approve/deny a tool call before timing out. Set to `0` to wait indefinitely (no expiry). Min: 0. |
| `permissionGate`    | boolean | `true`   | When `true`, tool calls are gated through the policy engine + iOS approval flow. When `false`, all tool calls auto-run with no approval. |

### Runtime Environment

| Setting              | Type     | Default   | Description                                                                                                                                |
| -------------------- | -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `runtimePathEntries` | string[] | see below | Explicit PATH entries injected into pi's tool execution environment. No shell profile is sourced — these are the only directories on PATH. |
| `runtimeEnv`         | object   | `{}`      | Additional environment variables passed to pi's tool execution. String keys and string values only.                                        |

Default `runtimePathEntries`:

```json
[
  "~/.local/bin",
  "~/.cargo/bin",
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  "/usr/local/bin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin"
]
```

If you need tools from custom paths (e.g. `mise`, `pyenv`, `nvm`), add their bin directories here.

### TLS

| Setting                        | Type    | Default         | Description                                                                                           |
| ------------------------------ | ------- | --------------- | ----------------------------------------------------------------------------------------------------- |
| `tls.mode`                     | string  | `"self-signed"` | Transport security mode. See modes below.                                                             |
| `tls.certPath`                 | string  | -               | PEM certificate path. Required for `manual` mode.                                                     |
| `tls.keyPath`                  | string  | -               | PEM private key path. Required for `manual` mode.                                                     |
| `tls.caPath`                   | string  | -               | CA chain path. Used in `self-signed` mode for client certificate pinning.                             |
| `tls.allowInsecureNetworkHttp` | boolean | `false`         | Explicit escape hatch required to bind plain HTTP/WS to non-loopback interfaces with `mode=disabled`. |

New configs default to `"self-signed"` so iOS pairing uses HTTPS/WSS out of the box.
For legacy configs that still have `"disabled"`, first `oppi serve` auto-promotes
TLS to `"self-signed"`.

Modes:

| Mode          | Behavior                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `disabled`    | Plain HTTP/WS. No encryption. Non-loopback binds require `tls.allowInsecureNetworkHttp=true`; loopback dev binds still work.    |
| `tailscale`   | Requests/renews certs via `tailscale cert`. Requires MagicDNS + HTTPS certs enabled in tailnet DNS + connected `tailscale` CLI. |
| `self-signed` | Auto-generates cert material under `~/.config/oppi/tls/self-signed/`. Client must trust the CA.                                 |
| `manual`      | Uses `certPath` and `keyPath` you provide. Both are required.                                                                   |
| `auto`        | Auto-selects based on environment (Tailscale if available, else self-signed).                                                   |
| `cloudflare`  | Cloudflare Tunnel integration.                                                                                                  |

```bash
# Tailscale (recommended for LAN)
oppi config set tls '{"mode":"tailscale"}'

# Self-signed (containers, dev)
oppi config set tls '{"mode":"self-signed"}'

# Plain network HTTP is an explicit escape hatch, not a default
oppi config set tls '{"mode":"disabled","allowInsecureNetworkHttp":true}'
```

### Auto Title

| Setting             | Type    | Default | Description                                                                                                                                                              |
| ------------------- | ------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `autoTitle.enabled` | boolean | `false` | When `true`, auto-generates a 3-5 word task title from the first user message. Uses a standalone LLM call (no pi system prompt, no tool context).                        |
| `autoTitle.model`   | string  | -       | Model to use for title generation. Format: `"provider/model-id"`. When omitted, server-side auto-title generation is disabled. A cheap/fast local model works well here. |

```json
{
  "autoTitle": {
    "enabled": true,
    "model": "omlx/Qwen3.5-122B-A10B-4bit"
  }
}
```

### Subagents

Controls lifecycle of child sessions spawned via `spawn_agent`.

| Setting                                                        | Type     | Default   | Description                                                                                                                                 |
| -------------------------------------------------------------- | -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `extensions.subagents.maxDepth`                                | number   | `1`       | Max spawn depth. `1` = parent can spawn children, but children cannot spawn grandchildren. `0` = spawning disabled.                         |
| `extensions.subagents.autoStopWhenDone`                        | boolean  | `false`   | When `true`, a child that finishes its work and goes idle is stopped immediately. When `false`, children stay alive for follow-up messages. |
| `extensions.subagents.startupGraceMs`                          | number   | `60000`   | How long to wait for a child to produce its first output before giving up. Covers VM boot, model loading, and first LLM call. 60000 = 60s.  |
| `extensions.subagents.defaultWaitTimeoutMs`                    | number   | `1800000` | Default timeout for `spawn_agent(wait=true)` when the caller doesn't specify `timeout_seconds`. 1800000 = 30 min.                           |
| `extensions.subagents.modelPolicy.approvedModels`              | string[] | unset     | Optional allowlist for subagent model IDs. If set, `spawn_agent` rejects non-approved models.                                               |
| `extensions.subagents.modelPolicy.defaultModel`                | string   | unset     | Default model for subagents when `spawn_agent` omits `model`.                                                                               |
| `extensions.subagents.modelPolicy.defaultThinking`             | string   | unset     | Default thinking level for subagents when `spawn_agent` omits `thinking`.                                                                   |
| `extensions.subagents.modelPolicy.profiles.<name>`             | object   | unset     | Named lane preset such as `discovery`, `coding`, `review`, or `web_research`.                                                               |
| `extensions.subagents.modelPolicy.profiles.<name>.model`       | string   | unset     | Model override for that profile.                                                                                                            |
| `extensions.subagents.modelPolicy.profiles.<name>.thinking`    | string   | unset     | Thinking override for that profile.                                                                                                         |
| `extensions.subagents.modelPolicy.profiles.<name>.guidelines`  | string[] | unset     | Extra prompt guidelines injected ahead of the child task.                                                                                   |
| `extensions.subagents.modelPolicy.profiles.<name>.activeTools` | string[] | unset     | Exact pi tool names to activate for children using this profile. Omitted means the child keeps the default active tool set.                 |

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
            "model": "openai-codex/gpt-5.4-mini",
            "thinking": "minimal",
            "guidelines": ["Prefer search before editing"],
            "activeTools": ["read", "grep", "find", "ls", "inspect_agent"]
          }
        }
      }
    }
  }
}
```

### ASR / Dictation

Configures server-side dictation routing to an external STT backend.

| Setting           | Type   | Default | Description                                                                                                                                                                                |
| ----------------- | ------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `asr.sttEndpoint` | string | -       | STT backend base URL. When set, server dictation is enabled on the session audio stream and audio is forwarded to the backend in real time. Oppi does not persist dictation audio locally. |

### Images

Controls client-side preprocessing for image attachments before upload.

| Setting             | Type    | Default | Description                                                                                                                                                                                              |
| ------------------- | ------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `images.autoResize` | boolean | `false` | When `true`, clients resize oversized image attachments before upload to fit a 2000 px max dimension and about a 4.5 MB base64 budget. When `false`, clients upload original image bytes where possible. |

### Policy

`policy` config controls the permission gate defaults. The runtime source of truth for allow/ask/deny tool rules is `~/.config/oppi/rules.json`; `policy.guardrails` and `policy.permissions` are seed inputs copied into `rules.json` when missing and then evaluated with learned/manual rules. Full evaluation order and pattern matching are documented in [policy-engine.md](policy-engine.md).

| Setting                | Type   | Default     | Description                                                                                                       |
| ---------------------- | ------ | ----------- | ----------------------------------------------------------------------------------------------------------------- |
| `policy.schemaVersion` | number | `1`         | Policy schema version. Must be `1`.                                                                               |
| `policy.mode`          | string | -           | Optional label for the policy preset (e.g. `"default"`, `"strict"`). Informational only.                          |
| `policy.description`   | string | -           | Human-readable description of the policy. Informational only.                                                     |
| `policy.fallback`      | string | `"allow"`   | Decision when no protected-path guard, heuristic, or `rules.json` rule matches: `"allow"`, `"ask"`, or `"block"`. |
| `policy.guardrails`    | array  | default set | Seed rules intended for hard safety defaults. Existing conflicting manual/user rules win during seeding.          |
| `policy.permissions`   | array  | default set | Seed rules intended for soft permissions/prompts. Existing conflicting manual/user rules win during seeding.      |
| `policy.heuristics`    | object | see below   | Runtime structural pattern detection. Catches dangerous patterns that simple matching misses.                     |

#### Guardrail / Permission Entry

Each entry in `guardrails` and `permissions`:

| Field                  | Required | Description                                                                  |
| ---------------------- | -------- | ---------------------------------------------------------------------------- |
| `id`                   | Yes      | Slug-like identifier. 3-64 chars, `[a-z0-9._-]`, must start with `[a-z0-9]`. |
| `decision`             | Yes      | `"allow"`, `"ask"`, or `"block"`.                                            |
| `label`                | No       | Short human-readable label shown in the iOS approval UI.                     |
| `reason`               | No       | Why this rule exists (shown in audit log).                                   |
| `match.tool`           | No       | Tool name: `"bash"`, `"read"`, `"edit"`, `"write"`.                          |
| `match.executable`     | No       | Binary name for bash commands (e.g. `"git"`, `"rm"`).                        |
| `match.commandMatches` | No       | Glob pattern against the full bash command string.                           |
| `match.pathMatches`    | No       | Glob pattern against file paths (read/edit/write).                           |
| `match.pathWithin`     | No       | Directory containment — matches if path is under this directory.             |
| `match.domain`         | No       | Domain match for network operations.                                         |

At least one `match.*` field is required per entry.

#### Heuristics

| Setting                              | Default   | What it catches                                                                                 |
| ------------------------------------ | --------- | ----------------------------------------------------------------------------------------------- |
| `policy.heuristics.pipeToShell`      | `"ask"`   | Piped execution: `curl ... \| bash`, `wget ... \| sh`, etc.                                     |
| `policy.heuristics.dataEgress`       | `"ask"`   | Bulk data exfiltration: large `curl`/`wget` POSTs, `scp`/`rsync` to external hosts.             |
| `policy.heuristics.secretEnvInUrl`   | `"ask"`   | URLs embedding env vars with secret-like names (`$AWS_SECRET_ACCESS_KEY`, `$TOKEN`).            |
| `policy.heuristics.secretFileAccess` | `"block"` | Reads/writes to credential files: `~/.ssh/id_*`, `~/.aws/credentials`, `.env` with secret keys. |

Each heuristic accepts `"allow"`, `"ask"`, `"block"`, or `false` (disabled).

Manual and user-learned rules live in `~/.config/oppi/rules.json`. After a rule exists there, editing `policy.guardrails` or `policy.permissions` does not rewrite or override it; use the policy UI/API or edit `rules.json` deliberately.

---

## Auth State (managed — do not edit)

These fields live in `config.json` but are managed by `oppi pair`, `oppi token rotate`, and the iOS client. Manual edits risk breaking authentication or push notifications.

| Field                   | Type     | Managed by                       | Description                                                                    |
| ----------------------- | -------- | -------------------------------- | ------------------------------------------------------------------------------ |
| `token`                 | string   | `oppi pair`, `oppi token rotate` | Owner bearer token. Used by all authenticated HTTP/WS requests.                |
| `pairingToken`          | string   | `oppi pair`                      | One-time bootstrap token. Short-lived (90s default). Consumed by `POST /pair`. |
| `pairingTokenExpiresAt` | number   | `oppi pair`                      | Pairing token expiry (epoch ms).                                               |
| `authDeviceTokens`      | string[] | `POST /pair`                     | Long-lived device tokens issued during pairing. Each iOS device gets one.      |
| `pushDeviceTokens`      | string[] | iOS client                       | APNs device tokens registered by iOS for push notifications.                   |
| `liveActivityToken`     | string   | iOS client                       | APNs token for iOS Live Activity updates.                                      |

Token matching: both `token` (owner) and `authDeviceTokens` (device) are accepted as Bearer tokens. Comparison uses constant-time equality to prevent timing attacks.

```bash
# Generate pairing QR code (issues pairingToken, prints QR)
oppi pair

# Rotate the owner token (invalidates existing, devices need re-pair)
oppi token rotate
```

---

## Full Example

```json
{
  "configVersion": 2,
  "port": 7749,
  "host": "0.0.0.0",
  "dataDir": "/Users/you/.config/oppi",
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000,
  "maxSessionsPerWorkspace": 20,
  "maxSessionsGlobal": 40,
  "approvalTimeoutMs": 120000,
  "permissionGate": true,
  "runtimePathEntries": ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"],
  "runtimeEnv": {},
  "tls": { "mode": "tailscale" },
  "autoTitle": { "enabled": true, "model": "omlx/Qwen3.5-122B-A10B-4bit" },
  "images": { "autoResize": false },
  "extensions": {
    "subagents": { "maxDepth": 1, "autoStopWhenDone": true }
  },
  "policy": {
    "schemaVersion": 1,
    "fallback": "allow",
    "guardrails": [],
    "permissions": [],
    "heuristics": {
      "pipeToShell": "ask",
      "dataEgress": "ask",
      "secretEnvInUrl": "ask",
      "secretFileAccess": "block"
    }
  }
}
```

## Agent-friendly config changes

Prefer the `oppi config` CLI over direct edits to `~/.config/oppi/config.json`. The CLI preserves managed auth fields, validates the result, and supports nested paths.

Examples:

```bash
oppi config get asr.sttEndpoint
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config set images.autoResize false
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config set extensions.voice.defaultVoiceId warm-technical-teammate
oppi config validate
```

Direct agent edits to `config.json` are protected and should require approval. Most server config changes need an Oppi server restart before they take effect.

## Validate

```bash
oppi config validate
```

Strict mode checks for unknown keys and reports them as errors. Normal startup mode (non-strict) ignores unknown keys and preserves valid fields.
