<p align="center">
  <img src="docs/images/app-icon.png" width="128" height="128" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Use <a href="https://github.com/badlogic/pi-mono">pi</a> from iPhone and iPad.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/toolcalling-demo.mp4">Demo video</a> · <a href="docs/demo/">Screenshots</a>
</p>

There are many clankers, and this one is mine. Oppi pairs an iPhone and iPad client with a server you run yourself for [Pi](https://github.com/badlogic/pi-mono) coding sessions.

Oppi keeps Pi's messages, tool calls, and extension UI visible on iOS. You can review and steer sessions from native iPhone and iPad views.

## How it works

Oppi supports two session paths:

- **SDK sessions:** `oppi-server` embeds the Pi SDK in-process for tool execution, event streaming, and standard Pi extension UI.
- **TUI bridge:** the `oppi-mirror` extension mirrors a terminal-owned Pi session in Oppi.

Oppi renders extension prompts, confirmations, editor requests, status, and widgets as iOS cards, editor sheets, rows, panels, or fallback text. Pi continues to own extension behavior, tools, providers, and session files.

```
┌─────────────────────┐
│   iPhone / iPad     │
│        Oppi         │
└──────────┬──────────┘
           │ HTTPS / WSS (Tailscale supported)
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

The Workspaces tab opens **All Sessions** for the active server. It keeps **Your Turn** and **Working** at the top, groups recent stopped sessions by day, and shows each workspace name. Use the sidebar or drawer to manage saved Agents and schedules, collapse the workspace list, open App Settings, or browse a workspace's sessions, files, and settings.

The create and edit sheets for Agents, schedules, workspaces, and Skills can open a **Pi Control** session. Pi Control is ordinary Pi with global settings, tools, Skills, Extensions, `SYSTEM.md`, and `APPEND_SYSTEM.md`. It runs with the server host user's permissions and can use the installed `oppi` CLI through `bash`. You can also use the native forms in the same sheets.

**Quick Session** starts a session without opening a workspace first. Launch it from Oppi, Control Center, the Action Button, Spotlight, Siri, or Shortcuts. The Shortcuts **New Session** action can add optional text and one image to the composer.

The iOS share extension accepts text, URLs, images, and files. Choose a paired-server workspace in its Quick Session composer, then start the session from the share sheet.

## Quick start

You need Node.js 24+ and at least one Pi provider configured through `pi auth` or an API key such as `ANTHROPIC_API_KEY`. Self-signed TLS on Linux also requires `openssl` on PATH.

Install and start:

```bash
npm install -g oppi-server
oppi serve
```

On first run, `oppi serve` creates `~/.config/oppi/`, generates owner credentials, starts local HTTPS/WSS, and prints a pairing QR code and invite link. In the iOS TestFlight app, choose **Scan QR Code** or **Enter manually**. You can also open the printed `oppi://connect` link on your phone.

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

With the default HTTP/TLS transport, the phone must reach the server over LAN, Tailscale, or a public hostname. For remote HTTP pairing, include the host in the invite:

```bash
oppi pair --host <hostname-or-ip>
```

Supported remote access is authenticated HTTPS/WSS, including through Tailscale.

Notes:

- `--host` expects host/IP only (no `https://`, no `:port`).
- Invites are single-use and short-lived (90 seconds by default). If pairing fails, generate a fresh invite.
- Invite port comes from server config (`oppi config get port`).

To include your Tailscale host in the first QR code from `serve`, run:

```bash
oppi serve --host <your-host>.ts.net
```

### Source checkout (development)

Use the repository installer only when developing Oppi or testing unreleased server changes:

```bash
git clone https://github.com/duh17/oppi.git
cd oppi
bash install.sh
```

For regular use, install from npm. Then update with `npm install -g oppi-server@latest`.

### Background service (macOS)

If you used `oppi server install`, a LaunchAgent starts the server at login and restarts it after a crash. Manage it with:

```bash
oppi server status     # check if running
oppi server restart    # restart
oppi server uninstall  # remove
```

## Commands

After installing `oppi-server` from npm, use these common commands:

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
oppi update                  # update the npm-installed server and CLI
```

You can manage saved Agents and schedules from the Oppi sidebar or server CLI/API. Saved Agents store reusable definitions and can use one Unicode emoji or SF Symbol name as an icon. The icon appears in Agent management and sessions started from that Agent. Clearing it restores the generic Agent icon.

Schedules support `at`, `every`, and `cron` triggers. Each schedule can target a workspace, saved Agent, or existing session. Oppi keeps run history for manual and approved automatic runs.

Control sessions pass Agent and schedule changes through size-limited `--definition-json` arguments instead of temporary files. Run `oppi --help` or see [server/README.md](server/README.md) for all commands.

## Mac app shell (experimental)

The macOS app, human users, and managed host sessions share the globally installed `oppi` command. The app does not bundle another server. Install or update it first:

```bash
npm install -g oppi-server@latest
```

`oppi init`, local status, and pairing work before you pair a phone. Workspace, session, Agent, and schedule commands require the local owner credentials created during setup.

## Docs

- [Contributing](CONTRIBUTING.md) - open an issue before proposing code changes
- [Changelog](CHANGELOG.md) - release history and versioning policy
- [Server README](server/README.md) - server setup, Docker, development
- [Onboarding and pairing](docs/onboarding.md) - first-run flow
- [Deep links](docs/deeplinks.md) - custom URL schemes for pairing, workspaces, and sessions
- [Config schema](server/docs/config-schema.md) - all config options
- [Dictation / ASR](server/docs/asr.md) - server dictation setup
- [Voice replies / TTS](server/docs/tts.md) - voice extension setup
- [Extensions](docs/extensions.md) - Oppi-specific extension behavior, workspace filtering, and mobile rendering rules
- [Attachment rendering](docs/attachment-rendering.md) - message and tool-output rendering for image, audio, video, and file attachments
- [Document viewers](docs/document-viewers.md) - full-screen reading controls for markdown, code, diffs, terminal output, and rendered documents
- [TUI session bridge](docs/oppi-mirror.md) - live terminal Pi sessions in Oppi and the separate `oppi-mirror` package
- [Sandbox workspaces](docs/sandbox.md) - Gondolin VM isolation, network boundaries, tools, and safe defaults
- [Custom themes](server/docs/themes.md) - creating color themes for the iOS app
- [Telemetry and diagnostics](docs/telemetry.md) - privacy controls, storage paths, latency, and reliability metrics
- [Provider quotas](docs/provider-quotas.md) - remaining usage windows and snapshot pace
- [Security](SECURITY.md) - security model and privacy

### Development docs

- [Architecture](docs/architecture.md) - cross-system architecture map
- [Server architecture](docs/architecture-server.md) - routes, streams, runtime ownership, and storage
- [Client architecture](docs/architecture-client.md) - Apple stores, transports, and the chat timeline pipeline
- [Extension native UI](docs/extension-native-ui.md) - native extension UI contract
- [Testing](docs/testing/README.md) - standard test commands
- [Model selection](server/docs/model-selection.md) - chat model selection precedence
- [Session tree semantics](server/docs/session-tree-semantics.md) - session tree and fork semantics
- [Protocol snapshots](protocol/README.md) - wire fixtures and stream topology

## License

[MIT](LICENSE)
