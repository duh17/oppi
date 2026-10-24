<p align="center">
  <img src="docs/images/app-icon.png" width="128" height="128" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Use <a href="https://github.com/badlogic/pi-mono">pi</a> from iPhone and iPad.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/#demos">See it</a> · <a href="docs/demo/#screenshots">Screenshots</a>
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

**Edit with Oppi** (and the create composers for Agents, schedules, themes, and workspaces) opens a **Pi Control** setup session. It uses Oppi's own short prompt, with no global `SYSTEM.md`, `APPEND_SYSTEM.md`, `AGENTS.md`, or Skills, and only `read`, `bash`, `edit`, `write`, and `ask` as tools. It runs as the server host user and uses the installed `oppi` CLI through `bash`. See [Pi Control sessions](docs/extensions.md#pi-control-sessions). You can also use the native forms in the same sheets.

**Quick Session** starts a session without opening a workspace first. Launch it from Oppi, Control Center, the Action Button, Spotlight, Siri, or Shortcuts. The **Live Voice** control starts a new session straight into a Live Voice call, and the Shortcuts **New Session** action picks the mode (Message, Dictation, Live Voice), Agent, workspace, text, and image.

The iOS share extension accepts text, URLs, images, and files. Choose a paired-server workspace in its Quick Session composer, then start the session from the share sheet.

## Quick start

On a Mac or Linux machine, install the server, start it as a background service, and show a pairing code. The installer needs no `sudo` and downloads Node.js 22 if the machine has no Node.js 22.19+:

```bash
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | sh
```

Run it again to upgrade. [Onboarding](docs/onboarding.md) lists what it changes and how to do the same from the iPhone over SSH. Sessions need at least one model provider: add one in the app under **Server Settings → Model Providers**, or see [Connect a model provider](docs/onboarding.md#connect-a-model-provider). Sandbox workspaces also need QEMU. Self-signed TLS on Linux also requires `openssl` on PATH.

To manage Node.js 22.19+ yourself, install with npm instead:

```bash
npm install -g oppi-server
oppi serve
```

On first run, `oppi serve` creates `~/.config/oppi/`, generates owner credentials, starts local HTTPS/WSS, and prints a pairing QR code and invite link. In the iOS TestFlight app, choose **Scan QR Code**, **Connect through Tailscale**, or **Enter manually**. Tailscale opens the in-app connection; it does not sign in by itself. You can also open the printed `oppi://connect` link on your phone.

To run an npm install as a background service (macOS LaunchAgent or Linux systemd user service; the installer does this for you):

```bash
oppi server install
oppi server status
```

Upgrade an installer install by running the installer again. Upgrade or uninstall an npm install with npm:

```bash
oppi update                 # same check the iPhone Server screen uses
npm install -g oppi-server@latest
npm uninstall -g oppi-server
```

On iPhone, **Server Settings** can update a globally installed `oppi-server` with one tap and reconnect after the process restarts. Other install kinds show the host command to copy; for an installer install that is the installer command. See [Using Oppi](docs/usage.md#server-settings).

With the default HTTP/TLS transport, the phone must reach the server over LAN, Tailscale, or a public hostname. For remote HTTP pairing, include the host in the invite:

```bash
oppi pair --host <hostname-or-ip>
```

Supported remote access is authenticated HTTPS/WSS, including through Tailscale.

Notes:

- `--host` expects host/IP only (no `https://`, no `:port`).
- Invites are single-use and short-lived (90 seconds by default; `oppi pair --ttl <1s to 30d>` changes it). If pairing fails, generate a fresh invite.
- Invite port comes from server config (`oppi config get port`).

To include your Tailscale host in the first QR code from `serve`, run:

```bash
oppi serve --host <your-host>.ts.net
```

### Source checkout (development)

Use a source checkout only when developing Oppi or testing unreleased server changes:

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
bash setup.sh
```

The root `install.sh` is the managed installer from [Onboarding](docs/onboarding.md#install); it installs the published package, not the checkout.

For regular use, use the installer from [Quick start](#quick-start), or npm.

### Background service

The installer and `oppi server install` set up a background service that restarts the server after a crash: a LaunchAgent on macOS (starts at login), a systemd user service on Linux (starts at boot when lingering is on; see [Keep it running](docs/onboarding.md#keep-it-running)). Manage it with:

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
oppi pair [--host <h>] [--ttl <d>]  # regenerate pairing QR + invite link
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

The macOS app, human users, and managed host sessions share the globally installed `oppi` command. The app does not bundle another server; it bundles only a signed Node runtime (`Contents/Resources/Helpers/node`, code-signing identifier `dev.chenda.OppiMac.server`) that runs that CLI, so the server does not use Homebrew Node when the app manages it. Install or update the CLI first:

```bash
npm install -g oppi-server@latest
```

`oppi init`, local status, and pairing work before you pair a phone. Workspace, session, Agent, and schedule commands require the local owner credentials created during setup.

## Docs

Start at [docs/index.md](docs/index.md). Public docs are two tracks: daily use and extension authoring. Pi slash commands, skills, compaction, and the TUI stay in [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md).

### Daily use

- [Onboarding and pairing](docs/onboarding.md)
- [Using Oppi](docs/usage.md) — screens, prompt vs steer vs follow-up, Quick Session, files, voice, Edit with Oppi
- [Custom themes](docs/themes.md)
- [Server configuration](docs/server-configuration.md)
- [Reverse proxy](docs/reverse-proxy.md)
- [Sandbox workspaces](docs/sandbox.md)
- [Oppi Mirror](docs/oppi-mirror.md)
- [SSH Terminal](docs/ssh-terminal.md)
- [Document viewers](docs/document-viewers.md)
- [Provider quotas](docs/provider-quotas.md)
- [Deep links](docs/deeplinks.md)
- [Support](docs/support.md)
- [Privacy](docs/privacy.md)
- [Screenshots](docs/demo/)

### Extension authoring

- [Extension behavior](docs/extensions.md) — what Oppi loads, mobile rules, Oppi event channels, durable extensions; Pi owns the tool API
- [Extension native UI](docs/extension-native-ui.md)
- [Attachment rendering](docs/attachment-rendering.md)
- [Pi extensions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md)

## Contributor docs

- [Contributor docs](dev/README.md) — architecture, leftover transport notes, telemetry, and testing
- [Architecture](dev/architecture.md)
- [Testing](dev/testing/README.md)
- [Telemetry](dev/telemetry.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Server README](server/README.md)
- [Config schema](server/docs/config-schema.md)
- [Dictation / ASR](server/docs/asr.md)
- [Voice replies / TTS](server/docs/tts.md)
- [Model selection](server/docs/model-selection.md)
- [Session tree semantics](server/docs/session-tree-semantics.md)
- [Protocol snapshots](protocol/README.md)
- [Security](SECURITY.md)

## License

[MIT](LICENSE)
