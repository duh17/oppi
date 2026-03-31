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

## Mac App (recommended on macOS)

**Oppi for Mac** is a menu bar companion app that manages the local server and handles onboarding. It's the easiest way to get started.

**Requirements:** macOS 15+, [pi](https://github.com/badlogic/pi-mono) CLI. The app bundles its own JS runtime (Bun); no separate Node.js install needed.

**Install:**
1. Download the DMG from [Releases](../../releases)
2. Drag Oppi to Applications and launch it
3. Follow the setup wizard (checks prerequisites, requests permissions, initializes the server)
4. Scan the QR code from the Oppi iOS app

The Mac app manages the server process automatically — start, stop, restart, and crash recovery. It also shows a stats dashboard with session counts, costs, and model breakdowns. For Linux, headless servers, or manual control, use the [CLI](#install) instead.

---

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

```bash
git clone https://github.com/duh17/oppi.git
cd Oppi/server
npm install
```

Requires Node.js 20+ and a [pi](https://github.com/badlogic/pi-mono) auth setup (`pi login`).

## Run

```bash
npx oppi serve
```

On first run, the server auto-initializes config and shows a pairing QR code. Scan it in the Oppi iOS app. Your phone and server need to be on the same local network. For off-LAN access via Tailscale, pair with your tailnet host: `npx oppi pair --host <your-host>.ts.net`.

If the auto-detected hostname isn't reachable from your phone, pass one explicitly:

```bash
npx oppi serve --host my-machine.local
```

## What you can do

[Screenshots and demo video](docs/demo/)

## Commands

```
npx oppi serve [--host <h>]      start server (auto-inits on first run)
npx oppi pair [--host <h>]       regenerate pairing QR
npx oppi status                  server config and connection overview
npx oppi doctor                  check prerequisites
npx oppi init                    interactive first-time setup
npx oppi config show             current config
npx oppi config set <k> <v>      update config value
npx oppi config get <k>          get single config value
npx oppi config validate         validate config file
npx oppi token rotate            rotate owner auth token
```

## Docs

- [Server README](server/README.md) — server setup, Docker, development
- [Config schema](server/docs/config-schema.md) — all config options
- [Policy engine](server/docs/policy-engine.md) — permission rules and heuristics
- [Extensions](docs/extensions.md) — Oppi-specific extension behavior, workspace filtering, and mobile rendering gotchas
- [Custom themes](docs/theme-system.md) — creating color themes for the iOS app
- [Telemetry and privacy](docs/telemetry.md) — what data is collected (short answer: none)
- [Security](SECURITY.md) — security model and privacy

## License

[MIT](LICENSE)
