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

Use the npm package for normal installs:

```bash
npm install -g oppi-server
oppi serve
```

On first run, `oppi serve` creates `~/.config/oppi/`, generates owner credentials, boots local HTTPS/WSS, and prints a pairing QR code and invite link. In the iOS TestFlight app, choose **Pair with server** and scan the QR code.

To run Oppi as a background service on macOS:

```bash
oppi server install
oppi server status
```

Upgrade or uninstall with npm:

```bash
npm install -g oppi-server@latest
npm uninstall -g oppi-server
```

Your phone and server must be reachable over LAN, Tailscale, or a public hostname. For remote pairing (Tailscale or VPS), generate invites with an explicit host:

```bash
oppi pair --host <hostname-or-ip>
```

Notes:

- `--host` expects host/IP only (no `https://`, no `:port`).
- Invite is single-use and short-lived (90 seconds by default). If pairing fails, generate a fresh invite.
- Invite port comes from server config (`oppi config get port`).

If you want first-run QR output from `serve` to already use your Tailscale host, start with:

```bash
oppi serve --host <your-host>.ts.net
```

### Source checkout (development)

Use the repo bootstrapper only when you are developing Oppi or testing unreleased server changes:

```bash
git clone https://github.com/duh17/oppi.git
cd oppi
bash install.sh
```

For regular use, prefer the npm route above so updates are just `npm install -g oppi-server@latest`.

### Background service (macOS)

If you used `oppi server install`, the server runs as a LaunchAgent that starts on login and restarts on crash. Manage it with:

```bash
oppi server status     # check if running
oppi server restart    # restart
oppi server uninstall  # remove
```

## What you can do

[Screenshots and demo video](docs/demo/)

## Commands

Use `oppi ...` after installing `oppi-server` from npm.

```
oppi serve [--host <h>]      start server
oppi pair [--host <h>]       regenerate pairing QR
oppi status                  server config overview
oppi doctor                  check prerequisites
oppi update                  update mutable runtime dependencies
oppi update --self           update the global npm server install
oppi init                    interactive first-time setup
oppi config show             current config
oppi config set <k> <v>      update config value
oppi config validate         validate config file
oppi token rotate            rotate owner auth token
oppi server install          install LaunchAgent (macOS)
oppi server uninstall        remove LaunchAgent
oppi server status           check background service
oppi server restart          restart background server
oppi server stop             stop background server
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
