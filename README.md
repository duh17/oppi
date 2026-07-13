<p align="center">
  <img src="docs/images/app-icon.png" width="128" height="128" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Use <a href="https://github.com/badlogic/pi-mono">pi</a> from iPhone and iPad.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/toolcalling-demo.mp4">Demo video</a> · <a href="docs/demo/">Screenshots</a>
</p>

There are many clankers and this one is mine: an iPhone/iPad client and self-hosted server for [Pi](https://github.com/badlogic/pi-mono) coding agent sessions.

The goal is to bring Pi's transparency and extensibility to native iOS, render clanker output and tool use nicely, and make it easy to review and steer sessions from mobile devices.

## How it works

Oppi has two session paths:

- **SDK sessions:** the server embeds the Pi SDK in-process, with tool execution, streaming, and standard Pi extension UI.
- **TUI bridge:** the `oppi-mirror` extension projects a terminal-owned Pi session into Oppi.

Extension prompts, confirmations, editor requests, status, and widgets render as iOS cards, editor sheets, rows, panels, or fallback text. Extension behavior, tools, providers, and session files stay in Pi.

```
┌─────────────────────┐
│   iPhone / iPad     │
│        Oppi         │
└──────────┬──────────┘
           │ HTTPS / WSS
           │ session stream + Pi extension UI
┌──────────▼──────────┐
│     oppi-server     │
│       Node.js       │
└──────────┬──────────┘
           │ pi SDK / TUI
┌──────────▼──────────┐
│    LLM provider     │
│      + tools        │
└─────────────────────┘
```

## Using Oppi

The Workspaces tab opens **All Sessions** for the active server. It keeps **Your Turn** and **Working** up top, groups recent stopped sessions by day, and shows workspace names on rows. Open the workspace sidebar or drawer to browse one workspace's sessions, files, and settings.

**Quick Session** starts a session without navigating into a workspace first. Open it from Oppi, Control Center, the Action Button, Spotlight, Siri, or Shortcuts. The Shortcuts **New Session** action can preload optional text and one image into the composer.

The iOS share extension accepts shared text, URLs, images, and files. Pick a paired-server workspace in the extension's Quick Session composer and start the session directly from the share sheet.

## Quick start

Requires Node.js 23.6+ and at least one Pi provider configured (`pi auth`, or an API key such as `ANTHROPIC_API_KEY`). Linux self-signed TLS also requires `openssl` on PATH.

Install and start:

```bash
npm install -g oppi-server
oppi serve
```

On first run, `oppi serve` creates `~/.config/oppi/`, generates owner credentials, boots local HTTPS/WSS, and prints a pairing QR code plus invite link. In the iOS TestFlight app, pair with one of the visible options: **Pair Nearby Mac**, **Scan QR Code**, or **Enter manually**. Opening the printed `oppi://connect` invite link on the phone also starts pairing.

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
- Invites are single-use and short-lived (90 seconds by default). If pairing fails, generate a fresh invite.
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

## Commands

Use `oppi ...` after installing `oppi-server` from npm. Common entry points:

```bash
oppi serve [--host <h>]      # start server
oppi init                    # interactive first-time setup
oppi pair [--host <h>]       # regenerate pairing QR + invite link
oppi status                  # server, network, and pairing status
oppi doctor                  # security and environment diagnostics
oppi workspace ...           # list/create/update/delete workspaces
oppi worktree ...            # list/create/open/preview/remove worktrees
oppi session ...             # create/send/watch/wait/inspect/resume/fork/delete sessions
oppi agent ...               # manage saved Agents
oppi schedule ...            # manage schedules and run history
oppi server ...              # install/status/restart/stop/uninstall launchd service
oppi config ...              # show/get/set/validate config
oppi token rotate            # rotate owner bearer token
oppi update                  # update mutable runtime dependencies
oppi update --self           # show how to update the server install
```

Saved Agents and schedules are server CLI/API features. Saved Agents hold reusable Agent definitions. Schedules store at/every/cron triggers plus a workspace, saved Agent, or existing-session action and keep run history for manual or approved automatic runs. For the full CLI surface, run `oppi --help` or see [server/README.md](server/README.md).

## Mac app shell (experimental)

The macOS app is an experimental shell with early configuration views. It is not a supported Pi session UI yet.

For normal use, run the server with the CLI above and pair from the iPhone/iPad app.

## Docs

- [Changelog](CHANGELOG.md) - release history and versioning policy
- [Server README](server/README.md) - server setup, Docker, development
- [Onboarding and pairing](docs/onboarding.md) - intended first-run user flow
- [Deep links](docs/deeplinks.md) - custom URL schemes for pairing, workspaces, and sessions
- [Config schema](server/docs/config-schema.md) - all config options
- [Dictation / ASR](server/docs/asr.md) - server dictation setup
- [Voice replies / TTS](server/docs/tts.md) - voice extension setup
- [Extensions](docs/extensions.md) - Oppi-specific extension behavior, workspace filtering, and mobile rendering gotchas
- [Attachment rendering](docs/attachment-rendering.md) - message and tool-output rendering for image, audio, video, and file attachments
- [Document viewers](docs/document-viewers.md) - full-screen reading controls for markdown, code, diffs, terminal output, and rendered documents
- [TUI session bridge](docs/oppi-mirror.md) - live terminal Pi sessions in Oppi and the separate `oppi-mirror` package
- [Sandbox workspaces](docs/sandbox.md) - Gondolin VM isolation, network boundaries, tools, and safe defaults
- [Custom themes](server/docs/themes.md) - creating color themes for the iOS app
- [Telemetry and diagnostics](docs/telemetry.md) - privacy controls, storage paths, latency, and reliability metrics
- [Security](SECURITY.md) - security model and privacy

### Development docs

- [Architecture](docs/architecture.md) - cross-system architecture map
- [Server architecture](docs/architecture-server.md) - routes, streams, runtime ownership, and storage
- [Client architecture](docs/architecture-client.md) - Apple stores, transports, and the chat timeline pipeline
- [Extension native UI](docs/extension-native-ui.md) - native extension UI contract
- [Testing](docs/testing/README.md) - canonical test commands
- [Model selection](server/docs/model-selection.md) - chat model selection precedence
- [Session tree semantics](server/docs/session-tree-semantics.md) - session tree and fork semantics
- [Protocol snapshots](protocol/README.md) - canonical wire fixtures and stream topology

## License

[MIT](LICENSE)
