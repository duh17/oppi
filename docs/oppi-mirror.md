# Oppi Mirror mode

Oppi Mirror makes an interactive terminal `pi` session visible in Oppi as a live session. The terminal keeps execution ownership. Through the bridge, Oppi can watch output, send prompts, steer the active turn, queue follow-ups, answer extension UI, and stop or abort.

Use mirror mode to open the same Pi session in both places: the terminal for hands-on work and Oppi for mobile viewing and steering.

Do not use mirror mode for server-owned SDK sessions, `pi -p`, JSON mode, RPC mode, or other non-interactive Pi processes.

## Prerequisites

- Oppi server `0.47.0` or newer is running.
- The owner-only local socket exists at `$OPPI_DATA_DIR/run/oppi.sock` (normally `~/.config/oppi/run/oppi.sock`).
- You are starting Pi in interactive terminal mode.

## Install from npm

Install public extension packages from npm with Pi's `npm:` source prefix:

```bash
pi install npm:oppi-mirror
```

That records the package in Pi settings, installs it under `~/.pi/agent/npm/`, and loads the extension on future interactive `pi` launches.

For a one-off run without editing settings, use:

```bash
pi -e npm:oppi-mirror
```

Before upgrading the Oppi server, update an existing Mirror install:

```bash
pi update --extension npm:oppi-mirror
```

If Pi is already running, reload extensions:

```text
/reload
```

Start Pi in an interactive terminal:

```bash
pi
```

The extension connects the terminal session to Oppi automatically. Check the bridge from Pi:

```text
/oppi-mirror status
```

Stop or restart the bridge:

```text
/oppi-mirror stop
/oppi-mirror start
```

## Configuration

By default, the extension connects over the owner-only Unix socket at `$OPPI_DATA_DIR/run/oppi.sock`. That upgrade is bearer-free. The network HTTPS/WSS listener does not expose `/mirror/v1/bridge`.

Override the socket for one process:

```bash
OPPI_MIRROR_SOCKET=/path/to/oppi.sock pi
```

Use a network URL only for explicit debug overrides. The live server rejects owner-token WSS upgrades on `/mirror/v1/bridge`:

```bash
OPPI_MIRROR_URL=https://127.0.0.1:7749 \
OPPI_MIRROR_TOKEN=your-token \
pi
```

Configure startup and missing-workspace behavior in `~/.pi/agent/settings.json`:

```json
{
  "oppiMirror": {
    "autoStart": false,
    "workspaceCreation": "ask"
  }
}
```

`workspaceCreation` accepts:

- `ask`: prompt in terminal Pi before creating a workspace. This is the default.
- `always`: create the workspace without prompting.
- `never`: do not create workspaces from mirror mode.

When creation is approved, Oppi uses the nearest parent git repo as the workspace root. If there is no git repo, it uses the terminal cwd.

For one process:

```bash
OPPI_MIRROR_AUTO_START=false \
OPPI_MIRROR_WORKSPACE_CREATION=never \
pi
```

## Commands

The extension adds one Pi command with these three actions:

```text
/oppi-mirror start
/oppi-mirror stop
/oppi-mirror status
```

`start` connects the current interactive Pi session to Oppi.

`stop` closes the bridge for the current session.

`status` reports whether the bridge is connected and, when available, shows the Oppi workspace and session IDs.

## Behavior

Mirror sessions appear in the normal Oppi session list. They use the same timeline, tool rendering, and stored session state as other Oppi sessions.

The terminal Pi process remains the source of truth. Oppi can watch, send prompts, steer the active turn, queue follow-ups, answer supported extension UI, and stop the session, but it does not silently take over execution.

In Oppi clients:

- connected mirror sessions show as `Mirror live`
- disconnected or stale mirror sessions show as `Mirror offline`
- stopped, disconnected mirror sessions can be resumed as server-owned Oppi sessions when the server has the session file

## What works from mobile

Mirror mode makes an active terminal session available in Oppi for viewing, prompts, and steering.

Supported from Oppi:

- prompts
- steer and follow-up messages
- stop or abort
- queue updates
- model and thinking-level changes
- session rename, compaction, and tree navigation
- standard Pi extension UI covered in the [compatibility matrix](#extension-ui-compatibility-matrix)
- Oppi AskCard requests with multi-select questions, with terminal fallback; this is Oppi-specific compatibility, not Pi's standard extension UI API

Still terminal-only:

- creating a new session
- fork and switch-session flows
- terminal-specific custom UI, headers, footers, custom editors, and raw TUI rendering unless the mirror bridge advertises a future native-snapshot capability
- session sharing from a mirrored session

## Extension UI compatibility matrix

| Pi or Oppi UI request | Mobile behavior | Terminal behavior |
| --- | --- | --- |
| `ctx.ui.select`, `ctx.ui.confirm`, `ctx.ui.input`, `ctx.ui.editor` | Native prompt; phone or terminal answer settles the request first | Terminal prompt remains available |
| `ctx.ui.notify`, `ctx.ui.setTitle`, `ctx.ui.setStatus`, `ctx.ui.setWidget` | Native banner, status, or surface when the request is semantic | Terminal UI remains terminal-owned |
| `ctx.ui.setWorkingMessage`, `ctx.ui.setWorkingVisible`, `ctx.ui.setWorkingIndicator` | Native working row text, visibility, and indicator state | Terminal UI remains terminal-owned |
| Oppi AskCard multi-select | Native AskCard, with first response winning | Terminal fallback |
| Custom terminal components, headers, footers, raw TUI layouts | Terminal-owned unless bridged as a semantic widget or future snapshot | Terminal-owned |

## Known limitations

- Mirror supports standard semantic Pi extension UI. Custom terminal component trees and raw ANSI/TUI layouts require an explicit bridge-forwarded snapshot or native-snapshot capability; otherwise they remain terminal-owned.
- Session-file replacement commands such as new session, fork, and switch session remain terminal-only.
- Session sharing from a mirrored session is not supported yet.

## Troubleshooting

### Debug logs

Mirror diagnostics are structured JSON lines.

- Server mirror logs: `~/.config/oppi/server.log`
- Terminal extension logs: `~/.config/oppi/oppi-mirror.log`

Useful fields: `sessionId`, `workspaceId`, `bridgeId`, `commandId`, `requestId`, `clientTurnId`, `command`, `outcome`, `durationMs`, `queueVersion`, `steeringCount`, and `followUpCount`.

### The bridge does not start

Run:

```text
/oppi-mirror status
```

If the extension cannot find the local Oppi socket, start the Oppi server once or set:

```bash
OPPI_MIRROR_SOCKET=/path/to/oppi.sock
```

### The extension starts in the wrong process

Mirror mode only starts from an interactive Pi TUI terminal. It must not run from SDK, print, JSON, or non-interactive processes.

Disable auto-start when needed:

```bash
OPPI_MIRROR_AUTO_START=false pi
```

### The session appears twice

The mirror session and local JSONL import must share the same `Session.id` (the Pi session UUID) and canonical session file. If duplicates appear, check the server’s mirror identity coalescing and local-session import behavior.
