<p align="center">
  <img src="docs/images/app-icon.png" width="80" height="80" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Supervise <a href="https://github.com/badlogic/pi-mono">pi</a> coding sessions from your phone.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/">Screenshots</a>
</p>

There are many clankers and this is mine. They wrote all the code and I didn't review most of it. I do use it every day — my goal was just to have a better mobile experience than tmux + Termius + Claude Code. Thanks to [pi](https://github.com/badlogic/pi-mono) and the new models, this is now possible :)

## Mac App (recommended on macOS)

**Oppi for Mac** is a menu bar companion app that manages the local server and handles onboarding. It's the easiest way to get started.

**Requirements:** macOS 15+, [Node.js](https://nodejs.org) v20+, [pi](https://github.com/badlogic/pi-mono) CLI

**Install:**
1. Download the DMG from [Releases](../../releases)
2. Drag Oppi to Applications and launch it
3. Follow the setup wizard (checks prerequisites, requests permissions, initializes the server)
4. Scan the QR code from the Oppi iOS app

The Mac app manages the server process automatically — start, stop, restart, and crash recovery — with no terminal needed. It also shows a stats dashboard with session counts, costs, and model breakdowns. For Linux, headless servers, or manual control, use the [CLI](#install) instead.

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
git clone https://github.com/duh17/Oppi.git
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

**Supervise sessions.** Start, stop, fork, and resume pi coding sessions from your phone. Stream output in real time with full markdown and tool call rendering.

**Approve tool calls.** The built-in policy engine catches dangerous operations (credential access, pipe-to-shell, sudo) and sends them to your phone. You choose allow or deny, with scope options (once, per-session, or globally).

**Manage workspaces.** Map workspaces to directories on your machine. Each workspace gets its own session history, git status, and policy config.

**Control models.** Switch LLM provider and model mid-session. Adjust thinking level. Queue steering messages while the agent is working, or follow-up messages for after it finishes.

**Run multi-agent.** Agents can spawn child sessions. You see the full tree from your phone — check status, inspect traces, drill into individual turns.

**Browse workspace files.** View files the agent has read or written. Fuzzy search, PDF/video/audio preview, rendered Org mode, LaTeX math, and Mermaid diagrams with pinch-to-zoom.

**View server stats.** Session counts, cost breakdowns by model and workspace, daily usage trends — all from the iOS app's Server tab.

**Connect multiple servers.** The iOS app supports multiple oppi-server instances. Switch between them or receive permission notifications from all at once.

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
- [Extensions](docs/extensions.md) — writing and using pi extensions with Oppi
- [Custom themes](docs/theme-system.md) — creating color themes for the iOS app
- [Telemetry and privacy](docs/telemetry.md) — what data is collected (short answer: none)
- [Security](SECURITY.md) — security model and privacy

## License

[MIT](LICENSE)
