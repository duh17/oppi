# Config Schema

Oppi server uses a JSON config file with validated fields and sensible defaults.

| Location                     | Scope            |
| ---------------------------- | ---------------- |
| `~/.config/oppi/config.json` | Default data dir |
| `$OPPI_DATA_DIR/config.json` | Custom data dir  |

Auto-created on first `oppi serve`, or manually via `oppi init`. Validated on load — invalid fields fall back to defaults with warnings. New fields are backfilled automatically on startup.

## All Settings

Settings are listed in the order they appear in the config file. Auth state is documented separately — it lives in the same file but is managed by CLI commands, not edited by hand.

### Server

| Setting         | Type   | Default            | Description                                                                    |
| --------------- | ------ | ------------------ | ------------------------------------------------------------------------------ |
| `configVersion` | number | `2`                | Schema version. Managed automatically — do not edit.                           |
| `port`          | number | `7749`             | HTTP + WebSocket listen port. Range: 0-65535.                                  |
| `host`          | string | `"0.0.0.0"`        | Bind address. Use `"127.0.0.1"` to restrict to localhost.                      |
| `dataDir`       | string | `"~/.config/oppi"` | Root state directory. Contains sessions, workspaces, config, and TLS material. |

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

### Extension UI Compatibility

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same bridge as other Pi extension UI.

Approval behavior is extension-owned. If a session needs approval before an action, install or enable a Pi extension that asks through `ctx.ui` or the built-in `ask` extension. No server-side approval config is required.

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
Configs with `tls.mode="disabled"` are auto-promoted to `"self-signed"` on first `oppi serve`.

Modes:

| Mode          | Behavior                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `disabled`    | Plain HTTP/WS. No encryption. Non-loopback binds require `tls.allowInsecureNetworkHttp=true`; loopback dev binds work.          |
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
  "runtimePathEntries": ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"],
  "runtimeEnv": {},
  "tls": { "mode": "tailscale" },
  "autoTitle": { "enabled": true, "model": "omlx/Qwen3.5-122B-A10B-4bit" },
  "images": { "autoResize": false }
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
