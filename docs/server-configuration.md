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

HTTP backend (Yuwp or any compatible streaming STT URL):

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi server restart   # or restart `oppi serve`
```

Pi package `./host` backend:

```bash
pi install @earendil-works/pi-transcribe
oppi config set asr.extension @earendil-works/pi-transcribe
oppi config set asr.backend pi-extension
oppi config validate
oppi server restart
```

- `asr.backend` is `http` or `pi-extension`. Omitted backend with a non-empty `sttEndpoint` means HTTP.
- Unset `asr.sttEndpoint` disables HTTP dictation. For `pi-extension`, Oppi ignores `sttEndpoint` and requires a valid `asr.extension` whose package directory exports `./host`.
- `asr.extension` must be a package name, an `npm:` spec, or an absolute package directory. It must not be a Node subpath or the TUI entry.
- Oppi does not install the package. Use `pi install` or an absolute package directory.
- The Apple app learns dictation availability from the server identity payload after pairing.

Inspect:

```bash
oppi config get asr
oppi config get asr.backend
oppi config get asr.extension
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
- [onboarding.md](onboarding.md) — install, pair, bind vs pairing host, LAN vs Tailscale, and `oppi status` / `oppi doctor`

Provider API keys use `pi auth`, not Oppi config.

## Common operator keys

| Key                                     | Notes                                                               |
| --------------------------------------- | ------------------------------------------------------------------- |
| `port`                                  | Listen port (restart)                                               |
| `host`                                  | HTTP/TLS **bind** address (restart). Do not use `0.0.0.0` on npm/VPS installs; bind a Tailscale `100.x` or LAN IP. Pairing advertise is `--host` / `OPPI_PAIR_HOST` / `pairHost`, not this key. |
| `pairHost`                              | Last advertised pairing hostname or IP from `oppi pair --host` / `oppi serve --host` (no scheme, no port). Not the bind address. |
| `tls.mode`                              | `disabled`, `self-signed`, `tailscale`, `manual` (restart). Use `tailscale` when the advertised pairing host is MagicDNS. |
| `asr.backend`                           | `http` or `pi-extension` (restart)                                  |
| `asr.extension`                         | Pi STT package name, `npm:` spec, or absolute package dir (restart) |
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
