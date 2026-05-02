<p align="center">
  <img src="docs/images/app-icon.png" width="128" height="128" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Run <a href="https://github.com/badlogic/pi-mono">pi</a> coding sessions from your phone.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/">Screenshots</a>
</p>

There are many clankers and this one is mine. iPhone app + self-hosted server + Mac companion for running [pi](https://github.com/badlogic/pi-mono) coding agent sessions from your phone. Stream output, approve tool calls, steer sessions, dictate prompts, attach screenshots — with native rendering that makes LLM output actually readable (no flickering).

All the code is written by agents. I haven't written or reviewed most of it — I describe features, try them on device, file bugs, and add tests so neither the agent nor I are hallucinating. I spent the last year doing Tailscale + tmux + Termius to use Claude Code from my phone. It worked until it didn't: no dictation, no image input, Ctrl-A N nightmares. So I built this.

The approach: [just talk to it](https://steipete.me/posts/just-talk-to-it), [feel it](https://mitchellh.com/writing/feel-it) by using it to build itself, and [measure everything](https://lucumr.pocoo.org/2025/6/17/measuring/). It mostly works, but there are [booboos everywhere](https://mariozechner.at/posts/2026-03-25-thoughts-on-slowing-the-fuck-down/). Unlike Mario, I have a high tolerance for booboos.

## How it works

The server embeds the [pi SDK](https://github.com/badlogic/pi-mono) directly — no separate CLI process. Each session runs an in-process agent with tool execution, streaming, and a policy-driven permission gate. The iOS app connects over WebSocket to stream output and handle approvals.

```
┌─────────┐        WSS / HTTPS        ┌──────────────┐
│  iPhone  │  ◄──────────────────────► │  oppi-server │
│  (Oppi)  │   stream, approvals, UI  │  (Node.js)   │
└─────────┘                            └──────┬───────┘
                                              │
                                      pi SDK (in-process)
                                              │
                                       ┌──────┴───────┐
                                       │ LLM provider  │
                                       │ + tools       │
                                       └──────────────-┘
```

## Install

Requires Node.js 23.6+ and [pi](https://github.com/badlogic/pi-mono) with at least one provider authenticated (`pi auth`). Linux self-signed TLS also requires `openssl` on PATH.

One-line bootstrap (choose one):

```bash
# Start in foreground (recommended for first run)
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | bash

# Install as a background service on macOS (launchd)
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | bash -s -- --install
```

Local clone flow (equivalent, choose one):

```bash
git clone https://github.com/duh17/oppi.git
cd oppi

# Foreground first run
bash install.sh

# Background service on macOS
bash install.sh --install
```

`install.sh` installs dependencies, builds, and either starts the server or installs a LaunchAgent. On first run, the server prints a pairing QR code and invite link.

Your phone and server must be reachable over LAN, Tailscale, or a public hostname. For remote pairing (Tailscale or VPS), generate invites with an explicit host:

```bash
cd server
node dist/src/cli.js pair --host <hostname-or-ip>
```

Notes:

- `--host` expects host/IP only (no `https://`, no `:port`).
- Invite is single-use and short-lived (90 seconds by default). If pairing fails, generate a fresh invite.
- Invite port comes from server config (`node dist/src/cli.js config get port`).

If you want first-run QR output from `serve` to already use your Tailscale host, start with:

```bash
node dist/src/cli.js serve --host <your-host>.ts.net
```

### Background service (macOS)

If you used `bash install.sh --install`, the server runs as a LaunchAgent that starts on login and restarts on crash. Manage it with:

```bash
node dist/src/cli.js server status     # check if running
node dist/src/cli.js server restart    # restart
node dist/src/cli.js server uninstall  # remove
```

## What you can do

[Screenshots and demo video](docs/demo/)

## Commands

All commands run from the `server/` directory.

```
node dist/src/cli.js serve [--host <h>]      start server
node dist/src/cli.js pair [--host <h>]       regenerate pairing QR
node dist/src/cli.js status                  server config overview
node dist/src/cli.js doctor                  check prerequisites
node dist/src/cli.js update                  update dependencies
node dist/src/cli.js init                    interactive first-time setup
node dist/src/cli.js config show             current config
node dist/src/cli.js config set <k> <v>      update config value
node dist/src/cli.js config validate         validate config file
node dist/src/cli.js token rotate            rotate owner auth token
node dist/src/cli.js server install          install LaunchAgent (macOS)
node dist/src/cli.js server uninstall        remove LaunchAgent
node dist/src/cli.js server status           check background service
node dist/src/cli.js server restart          restart background server
node dist/src/cli.js server stop             stop background server
```

## Mac App (experimental)

On macOS, there's also a menu bar companion app that manages the server and handles onboarding through a guided wizard. It bundles its own JS runtime (Bun) — no separate Node.js install needed.

The Mac app is experimental. For a more predictable setup, use the CLI above.

Requirements: macOS 15+, [pi](https://github.com/badlogic/pi-mono) CLI.

1. Download the DMG from [Releases](../../releases)
2. Drag Oppi to Applications and launch
3. Follow the setup wizard
4. Scan the QR code from the iOS app

## Docs

- [Server README](server/README.md) — server setup, Docker, development
- [Onboarding and pairing](docs/onboarding.md) — intended first-run user flow
- [Config schema](server/docs/config-schema.md) — all config options
- [Dictation / ASR](server/docs/asr.md) — server dictation setup
- [Voice replies / TTS](server/docs/tts.md) — voice extension setup
- [Policy engine](server/docs/policy-engine.md) — permission rules and heuristics
- [Extensions](docs/extensions.md) — Oppi-specific extension behavior, workspace filtering, and mobile rendering gotchas
- [Custom themes](server/docs/themes.md) — creating color themes for the iOS app
- [Telemetry and privacy](docs/telemetry.md) — what data is collected (short answer: none)
- [Security](SECURITY.md) — security model and privacy

## License

[MIT](LICENSE)
