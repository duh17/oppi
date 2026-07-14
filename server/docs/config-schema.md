# Config Schema

Oppi server uses a JSON config file with validated fields and sensible defaults.

| Location                     | Scope            |
| ---------------------------- | ---------------- |
| `~/.config/oppi/config.json` | Default data dir |
| `$OPPI_DATA_DIR/config.json` | Custom data dir  |

Auto-created on first `oppi serve`, or manually via `oppi init`. Validated on load — invalid fields fall back to defaults with warnings. New fields are backfilled automatically on startup.

## All settings

Settings are listed in the order they appear in the config file. Auth state is documented separately — it lives in the same file but is managed by CLI commands, not edited by hand.

### Server

| Setting         | Type   | Default            | Description                                                                                                     |
| --------------- | ------ | ------------------ | --------------------------------------------------------------------------------------------------------------- |
| `configVersion` | number | `2`                | Schema version. Managed automatically — do not edit.                                                            |
| `port`          | number | `7749`             | Remote HTTP(S) + WebSocket listen port. Range: 0-65535.                                                         |
| `host`          | string | `"0.0.0.0"`        | Remote bind address. Use `"127.0.0.1"` to restrict network clients to localhost.                                |
| `dataDir`       | string | `"~/.config/oppi"` | Root state directory. Contains sessions, workspaces, config, TLS material, and the local CLI runtime directory. |

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

### Session lifecycle

| Setting                   | Type   | Default   | Description                                                                                   |
| ------------------------- | ------ | --------- | --------------------------------------------------------------------------------------------- |
| `sessionIdleTimeoutMs`    | number | `600000`  | Stop sessions after this many ms of inactivity. 600000 = 10 min. Min: 1.                      |
| `workspaceIdleTimeoutMs`  | number | `1800000` | Stop workspace runtimes after this many ms with no active sessions. 1800000 = 30 min. Min: 1. |
| `maxSessionsPerWorkspace` | number | `100`     | Max concurrent sessions in a single workspace. Min: 1.                                        |
| `maxSessionsGlobal`       | number | `200`     | Max concurrent sessions across all workspaces. Min: 1.                                        |

Use `sessionIdleTimeoutMs` in config files.

### Oppi docs prompt

| Setting                  | Type    | Default | Description                                                                                                                                            |
| ------------------------ | ------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `oppiDocsPrompt.enabled` | boolean | `true`  | When `true`, Oppi-owned host sessions append a local packaged-docs hint to the Pi system prompt. Terminal-owned `pi-tui` and sandbox sessions skip it. |

```bash
oppi config set oppiDocsPrompt.enabled false
oppi config set oppiDocsPrompt.enabled true
```

### Runtime environment

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

### Local CLI transport

The local CLI always uses bearer-authenticated HTTP over an owner-only Unix socket. The normal path is `$OPPI_DATA_DIR/run/oppi.sock`; the runtime directory is mode `0700` and the socket is mode `0600`. If a custom data-directory path would exceed portable Unix socket limits, Oppi derives a deterministic owner-only socket path under the system temporary directory.

`host`, `port`, and `tls` configure only the remote network listener. The CLI does not fall back to TCP when its Unix socket is missing or unavailable.

### TLS

| Setting                        | Type    | Default         | Description                                                                                           |
| ------------------------------ | ------- | --------------- | ----------------------------------------------------------------------------------------------------- |
| `tls.mode`                     | string  | `"self-signed"` | Transport security mode. See modes below.                                                             |
| `tls.certPath`                 | string  | -               | PEM certificate path. Required for `manual` mode.                                                     |
| `tls.keyPath`                  | string  | -               | PEM private key path. Required for `manual` mode.                                                     |
| `tls.caPath`                   | string  | -               | CA chain path. Used in `self-signed` mode for client certificate pinning.                             |
| `tls.allowInsecureNetworkHttp` | boolean | `false`         | Explicit escape hatch required to bind plain HTTP/WS to non-loopback interfaces with `mode=disabled`. |

New configs default to `"self-signed"` so iOS pairing uses HTTPS/WSS out of the box. Configs with `tls.mode="disabled"` are auto-promoted to `"self-signed"` on first `oppi serve`. TLS applies to the remote network listener, not the local Unix socket.

Modes:

| Mode          | Behavior                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `disabled`    | Plain HTTP/WS. No encryption. Non-loopback binds require `tls.allowInsecureNetworkHttp=true`; loopback dev binds work.                                                                                                                                                                                                                                                                    |
| `tailscale`   | Uses a Tailnet DNS certificate and requests/renews it via `tailscale cert` when Tailscale is connected. Existing locally valid material can restart the remote listener while disconnected. Missing or invalid material leaves remote HTTPS/WSS unavailable without affecting the Unix-socket CLI. Tailscale is required to obtain or renew material and for remote Tailnet connectivity. |
| `self-signed` | Auto-generates cert material under `~/.config/oppi/tls/self-signed/`. Client must trust the CA.                                                                                                                                                                                                                                                                                           |
| `manual`      | Uses `certPath` and `keyPath` you provide. Both are required.                                                                                                                                                                                                                                                                                                                             |
| `auto`        | Auto-selects based on environment (Tailscale if available, else self-signed).                                                                                                                                                                                                                                                                                                             |
| `cloudflare`  | Cloudflare Tunnel integration.                                                                                                                                                                                                                                                                                                                                                            |

For Tailscale fallback, “locally valid” means the leaf parses, the current time
is within its complete validity interval, it has an exact Tailnet DNS SAN, and
the private key matches. Oppi assumes material produced by the local
`tailscale` command or supplied at configured paths has the intended
provenance. Startup and `oppi doctor` do not independently prove a public CA
chain; clients use normal TLS trust verification and no insecure verification
bypass is enabled.

```bash
# Tailscale (recommended for LAN)
oppi config set tls '{"mode":"tailscale"}'

# Self-signed (containers, dev)
oppi config set tls '{"mode":"self-signed"}'

# Plain network HTTP is an explicit escape hatch, not a default
oppi config set tls '{"mode":"disabled","allowInsecureNetworkHttp":true}'
```

### Auto title

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

### ASR / dictation

Configures server-side dictation routing to an external STT backend.

| Setting           | Type   | Default | Description                                                                                                                                                                                |
| ----------------- | ------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `asr.sttEndpoint` | string | -       | STT backend base URL. When set, server dictation is enabled on the session audio stream and audio is forwarded to the backend in real time. Oppi does not persist dictation audio locally. |

### Images

Controls client-side preprocessing for image attachments before upload.

| Setting             | Type    | Default | Description                                                                                                                                                                                              |
| ------------------- | ------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `images.autoResize` | boolean | `false` | When `true`, clients resize oversized image attachments before upload to fit a 2000 px max dimension and about a 4.5 MB base64 budget. When `false`, clients upload original image bytes where possible. |

### Extensions

| Setting                           | Type   | Default | Description                                                                          |
| --------------------------------- | ------ | ------- | ------------------------------------------------------------------------------------ |
| `extensions.voice.defaultVoiceId` | string | -       | Default saved voice ID used by the sample voice extension. See [`tts.md`](./tts.md). |

## Extension UI compatibility

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same bridge as other Pi extension UI.

Approval behavior is extension-owned. If a session needs approval before an action, install or enable a Pi extension that asks through `ctx.ui`, such as the `pi-extensions/ask` example. No Oppi-specific approval config is required.

## Full example

```json
{
  "configVersion": 2,
  "port": 7749,
  "host": "0.0.0.0",
  "dataDir": "/Users/you/.config/oppi",
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000,
  "maxSessionsPerWorkspace": 100,
  "maxSessionsGlobal": 200,
  "runtimePathEntries": ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"],
  "runtimeEnv": {},
  "oppiDocsPrompt": { "enabled": true },
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
oppi config set oppiDocsPrompt.enabled false
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
