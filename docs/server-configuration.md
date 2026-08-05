# Server configuration

Operator guide for the local Oppi server: config CLI, dictation (ASR), voice/TTS runtime settings, and extensions.

Config file: `~/.config/oppi/config.json`
Data directory: `~/.config/oppi/` (override with `OPPI_DATA_DIR` or `--data-dir`)

## Config CLI

```bash
oppi config show
oppi config get asr.sttEndpoint
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi config set --help
```

- Paths use dot notation (`tls.mode`, `runtimeEnv.TTS_BASE_URL`).
- `oppi config set` without enough arguments lists supported keys and current values.
- Unknown keys are ignored on startup and reported by `oppi config validate`.
- Many keys need a **server restart** before they take effect (`asr`, `tls`, `iroh`, `port`, `host`, `runtimeEnv`).

From the Oppi agent tool, the same commands are available under the approval policy. Prefer `config get` / `config show` before `config set`.

## Dictation (ASR / STT)

Dictation needs a speech-to-text backend URL:

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi server restart   # or restart `oppi serve`
```

- Unset `asr.sttEndpoint` disables remote dictation on the server.
- The Apple app learns dictation availability from the server identity payload after pairing.
- Point `asr.sttEndpoint` at a reachable STT service that Oppi can call from the server host.

Inspect:

```bash
oppi config get asr
oppi config get asr.sttEndpoint
```

## Voice / TTS

TTS is not a single built-in endpoint. Extensions provide synthesis. Common server-side pieces:

| Setting | Purpose |
| --- | --- |
| `runtimeEnv.TTS_BASE_URL` | Runtime env passed into the Oppi/Pi host process for a voice extension |
| `extensions.voice.defaultVoiceId` | Saved default voice id for the voice extension |

```bash
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config set extensions.voice.defaultVoiceId my-voice-id
oppi config validate
oppi server restart
```

Use `oppi config get runtimeEnv` and `oppi config get extensions.voice` to inspect. Extension-specific auth and models stay in the extension docs or its settings, not in core Oppi config.

## Extensions

Server-global Skills and Extensions are managed from the Apple app (**Skills** / **Extensions** destinations) and follow Pi user-scope resource rules. Read [extensions.md](extensions.md) for:

- the built-in **Oppi** extension (`oppi` tool) and approval policies
- how ordinary sessions discover Pi extensions
- native extension UI expectations

Useful companion docs:

- [extension-native-ui.md](extension-native-ui.md) — mobile-safe extension UI surfaces
- [onboarding.md](onboarding.md) — install, pair, Iroh
- [networking.md](networking.md) — HTTPS / Iroh routing

Provider API keys use `pi auth`, not Oppi config.

## Common operator keys

| Key | Notes |
| --- | --- |
| `port` / `host` | Listen address (restart) |
| `tls.mode` | `disabled`, `self-signed`, `tailscale`, `manual` (restart) |
| `iroh.enabled` / `iroh.relays` | Host-free transport (restart) |
| `asr.sttEndpoint` | Dictation STT backend (restart) |
| `runtimeEnv.<NAME>` | Host runtime env, including TTS URLs (restart) |
| `extensions.voice.defaultVoiceId` | Default voice id |
| `images.autoResize` | Client image preprocessing preference |
| `autoTitle.enabled` / `autoTitle.model` | Automatic session titles |

After config changes that need a restart:

```bash
oppi server restart
# or stop/start a foreground `oppi serve`
```

`oppi server restart` is operator-only. The Oppi agent tool can change config values but cannot restart the server; tell the user when a restart is required.

## What not to put in config

- Owner tokens and pairing secrets (use `oppi pair` / `oppi token`)
- Provider credentials (use `pi auth`)
- Per-workspace Agent/Skill content (use Agents, Skills, and workspace flows)

When unsure about a flag or subcommand, run nested help first:

```bash
oppi help config
oppi config set --help
oppi help
```
