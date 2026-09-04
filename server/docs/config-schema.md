# Config Schema

Oppi server uses a JSON config file with validated fields and defaults.

| Location                     | Scope            |
| ---------------------------- | ---------------- |
| `~/.config/oppi/config.json` | Default data dir |
| `$OPPI_DATA_DIR/config.json` | Custom data dir  |

Oppi creates the file on the first `oppi serve`. You can also create it with `oppi init`. On load, invalid fields fall back to defaults with warnings. Startup backfills new fields automatically.

## All settings

Settings appear in config-file order. Auth state is documented separately: it lives in the same file but CLI commands manage it, rather than hand edits.

### Server

| Setting         | Type   | Default            | Description                                                                                                     |
| --------------- | ------ | ------------------ | --------------------------------------------------------------------------------------------------------------- |
| `configVersion` | number | `2`                | Schema version. Managed automatically — do not edit.                                                            |
| `port`          | number | `7749`             | Remote HTTP(S) + WebSocket listen port. Range: 0-65535.                                                         |
| `host`          | string | `"0.0.0.0"`        | Remote bind address. Use `"127.0.0.1"` to restrict network clients to localhost.                                |
| `dataDir`       | string | `"~/.config/oppi"` | Root state directory. Contains sessions, workspaces, config, TLS material, and the local CLI runtime directory. |

Remote clients use authenticated HTTPS/WSS, including HTTPS through Tailscale.

### Model

Oppi does not own a default chat model. New chat sessions use the shared model-selection behavior in [`model-selection.md`](./model-selection.md): explicit model, inherited or source model, then Pi settings.

Configure the machine-wide fallback in Pi settings, for example in `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "xhigh"
}
```

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

Add bin directories for tools on custom paths, such as `mise`, `pyenv`, or `nvm`.

### Local CLI transport

The local CLI always uses bearer-authenticated HTTP over an owner-only Unix socket. Its normal path is `$OPPI_DATA_DIR/run/oppi.sock`; the runtime directory is mode `0700` and the socket is mode `0600`. If a custom data-directory path would exceed portable Unix socket limits, Oppi derives a deterministic owner-only socket path under the system temporary directory.

`host`, `port`, and `tls` configure only the remote network listener. The CLI never falls back to TCP when its Unix socket is missing or unavailable.

### TLS

| Setting                        | Type    | Default         | Description                                                                                           |
| ------------------------------ | ------- | --------------- | ----------------------------------------------------------------------------------------------------- |
| `tls.mode`                     | string  | `"self-signed"` | Transport security mode. See modes below.                                                             |
| `tls.certPath`                 | string  | -               | PEM certificate path. Required for `manual` mode.                                                     |
| `tls.keyPath`                  | string  | -               | PEM private key path. Required for `manual` mode.                                                     |
| `tls.caPath`                   | string  | -               | CA chain path. Used in `self-signed` mode for client certificate pinning.                             |
| `tls.allowInsecureNetworkHttp` | boolean | `false`         | Explicit escape hatch required to bind plain HTTP/WS to non-loopback interfaces with `mode=disabled`. |

New configs default to `"self-signed"`, so iOS pairing uses HTTPS/WSS by default. On the first `oppi serve`, configs with `tls.mode="disabled"` are auto-promoted to `"self-signed"`. TLS applies to the remote network listener, not the local Unix socket.

Modes:

| Mode          | Behavior                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `disabled`    | Plain network HTTP for health-only development. Pairing, device auth, authenticated remote APIs, and remote WebSockets reject it. Non-loopback binds require `tls.allowInsecureNetworkHttp=true`.                                                                                                                                                                                          |
| `tailscale`   | Uses a Tailnet DNS certificate and requests/renews it via `tailscale cert` when Tailscale is connected. Existing locally valid material can restart the remote listener while disconnected. Missing or invalid material leaves remote HTTPS/WSS unavailable without affecting the Unix-socket CLI. Tailscale is required to obtain or renew material and for remote Tailnet connectivity. |
| `self-signed` | Auto-generates cert material under `~/.config/oppi/tls/self-signed/`. Client must trust the CA.                                                                                                                                                                                                                                                                                           |
| `manual`      | Uses `certPath` and `keyPath` you provide. Both are required.                                                                                                                                                                                                                                                                                                                             |
| `auto`        | Auto-selects based on environment (Tailscale if available, else self-signed).                                                                                                                                                                                                                                                                                                             |
| `cloudflare`  | Cloudflare Tunnel integration.                                                                                                                                                                                                                                                                                                                                                            |

For Tailscale fallback, “locally valid” means the leaf parses, the current time
falls within its complete validity interval, it has an exact Tailnet DNS SAN,
and the private key matches. Oppi assumes material from the local `tailscale`
command or configured paths has the intended provenance. Startup and `oppi doctor` do not independently prove a public CA chain; clients use normal TLS trust verification, with no insecure-verification bypass enabled.

```bash
# Tailscale (recommended for LAN)
oppi config set tls '{"mode":"tailscale"}'

# Self-signed (containers, dev)
oppi config set tls '{"mode":"self-signed"}'

# Plain network HTTP is health-only; it cannot authenticate Apple clients
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

Configures routing for server-side dictation to an external STT backend.

| Setting           | Type   | Default | Description                                                                                                                                                                                |
| ----------------- | ------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `asr.sttEndpoint` | string | -       | STT backend base URL. When set, server dictation is enabled on the session audio stream and audio is forwarded to the backend in real time. Oppi does not persist dictation audio locally. Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored on load. |

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

Extensions own approval behavior. When a session needs approval before an action, install or enable a Pi extension that asks through `ctx.ui`, such as the `pi-extensions/ask` example. No Oppi-specific approval config is required.

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

Prefer the `oppi config` CLI to direct edits of `~/.config/oppi/config.json`. It preserves managed auth fields, validates the result, and supports nested paths.

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

Direct agent edits to `config.json` are protected and should require approval. Most server config changes require an Oppi server restart before they take effect.

## Validate

```bash
oppi config validate
```

Strict mode reports unknown keys as errors. Normal startup mode (non-strict) ignores unknown keys and preserves valid fields.
