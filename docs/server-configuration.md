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
- Many keys need a **server restart** before they take effect (`asr`, `tls`, `port`, `host`, `runtimeEnv`).

## Dictation (ASR / STT)

HTTP/Yuwp backend (Yuwp or any compatible streaming STT URL):

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi server restart   # or restart `oppi serve`
```

- Set a non-empty `asr.sttEndpoint` to enable server dictation. Unset it to disable.
- Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored on load.
- The Apple app learns dictation availability from the server identity payload after pairing.

Inspect:

```bash
oppi config get asr
oppi config get asr.sttEndpoint
```

## Voice / TTS

TTS is not a single built-in endpoint. Extensions provide synthesis. Common server-side pieces:

| Setting                           | Purpose                                                                |
| --------------------------------- | ---------------------------------------------------------------------- |
| `runtimeEnv.TTS_BASE_URL`         | Runtime env passed into the Oppi/Pi host process for a voice extension |
| `extensions.voice.defaultVoiceId` | Saved default voice id for the voice extension                         |

```bash
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config set extensions.voice.defaultVoiceId my-voice-id
oppi config validate
oppi server restart
```

Use `oppi config get runtimeEnv` and `oppi config get extensions.voice` to inspect. Extension-specific auth and models stay in the extension docs or its settings, not in core Oppi config.

## Extensions

Server-global Skills and Extensions are managed from the Apple app (**Skills** / **Extensions** destinations) and follow Pi user-scope resource rules. Read [extensions.md](extensions.md) for:

- how managed sessions discover Pi extensions
- the server-scoped Mobile Output Guide
- native extension UI expectations

Useful companion docs:

- [extension-native-ui.md](extension-native-ui.md) — mobile-safe extension UI surfaces
- [onboarding.md](onboarding.md) — install, pair, LAN vs Tailscale, and `oppi status` / `oppi doctor`

Provider API keys use `pi auth`, not Oppi config.

## Common operator keys

| Key                                     | Notes                                                               |
| --------------------------------------- | ------------------------------------------------------------------- |
| `port` / `host`                         | Listen address (restart)                                            |
| `tls.mode`                              | `disabled`, `self-signed`, `tailscale`, `manual` (restart)          |
| `asr.sttEndpoint`                       | HTTP dictation STT backend (restart)                                |
| `runtimeEnv.<NAME>`                     | Host runtime env, including TTS URLs (restart)                      |
| `extensions.voice.defaultVoiceId`       | Default voice id                                                    |
| `images.autoResize`                     | Client image preprocessing preference                               |
| `autoTitle.enabled` / `autoTitle.model` | Automatic session titles                                            |

After config changes that need a restart:

```bash
oppi server restart
# or stop/start a foreground `oppi serve`
```

`oppi server restart` is operator-only. A Pi Control session runs with host-user authority, so inspect the current state before changing configuration and tell the user when a restart is required.

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
