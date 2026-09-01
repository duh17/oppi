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

With the default HTTP/TLS transport, the phone must reach the server over LAN, Tailscale, or a public hostname. `config host` is the bind address — do not use `0.0.0.0` on npm/VPS installs. Bind a Tailscale or LAN IP (`oppi config set host <ip>`). For remote pairing, advertise MagicDNS or a hostname with `--host` / `OPPI_PAIR_HOST` (not by binding all interfaces):

```bash
oppi pair --host <hostname-or-ip>
```

When the advertised pairing host is MagicDNS, use `tls.mode=tailscale`. Supported remote access is authenticated HTTPS/WSS, including through Tailscale. `oppi doctor` fails on a wildcard bind on npm/VPS. Docker Compose keeps the in-container `0.0.0.0` listener; doctor warns there and the compose port mapping should bind a Tailscale or LAN IP. Doctor warns when the advertised pairing host is MagicDNS with self-signed TLS.

Notes:

- `--host` is the advertised pairing hostname, not the bind address. Host/IP only (no `https://`, no `:port`).
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

Start at [docs/index.md](docs/index.md). Public docs are two tracks: daily use and extension authoring. Pi slash commands, skills, compaction, and the TUI stay in [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md).

### Daily use

- [Using Oppi](docs/usage.md) — screens, prompt vs steer vs follow-up, Quick Session, files, voice
- [Onboarding and pairing](docs/onboarding.md)
- [Deep links](docs/deeplinks.md)
- [Document viewers](docs/document-viewers.md)
- [Sandbox workspaces](docs/sandbox.md)
- [Oppi Mirror](docs/oppi-mirror.md)
- [Provider quotas](docs/provider-quotas.md)
- [Server configuration](docs/server-configuration.md)
- [Support](docs/support.md)
- [Privacy](docs/privacy.md)
- [Screenshots](docs/demo/)

### Extension authoring

- [Extensions](docs/extensions.md) — Oppi overlay and mobile don'ts; Pi owns the tool API
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
- [Custom themes](server/docs/themes.md)
- [Model selection](server/docs/model-selection.md)
- [Session tree semantics](server/docs/session-tree-semantics.md)
- [Protocol snapshots](protocol/README.md)
- [Security](SECURITY.md)

## License

[MIT](LICENSE)
