# Oppi Mirror mode

Oppi Mirror makes an interactive terminal `pi` session visible in Oppi as a live session. The terminal keeps execution ownership; Oppi can watch output, send prompts, steer the active turn, queue follow-ups, answer extension UI, and stop or abort through the bridge.

Use mirror mode when you want the same Pi session open in both places: terminal for hands-on work, Oppi for mobile supervision.

Do not use mirror mode for server-owned SDK sessions, `pi -p`, JSON mode, RPC mode, or other non-interactive Pi processes.

## Prerequisites

- Oppi server `0.4.0` or newer is running.
- The server has a valid token in `~/.config/oppi/config.json`.
- You are starting Pi in interactive terminal mode.

## Install from npm

Pi installs public extension packages from npm with the `npm:` source prefix:

```bash
pi install npm:oppi-mirror
```

That records the package in Pi settings, installs it under `~/.pi/agent/npm/`, and loads the extension on future interactive `pi` launches.

For a one-off run without editing settings, use:

```bash
pi -e npm:oppi-mirror
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

By default, the extension reads the local Oppi server URL and token from `~/.config/oppi/config.json`.

Override the connection for one process:

```bash
OPPI_MIRROR_URL=http://127.0.0.1:8787 \
OPPI_MIRROR_TOKEN=your-token \
pi
```

Disable automatic startup in `~/.pi/agent/settings.json`:

```json
{
  "oppiMirror": {
    "autoStart": false
  }
}
```

Or disable it for one process:

```bash
OPPI_MIRROR_AUTO_START=false pi
```

## Commands

The extension adds one Pi command with three actions:

```text
/oppi-mirror start
/oppi-mirror stop
/oppi-mirror status
```

`start` connects the current interactive Pi session to Oppi.

`stop` closes the bridge for the current session.

`status` reports whether the bridge is connected and, when available, shows the Oppi workspace and session IDs.

## Behavior

Mirror sessions appear in the normal Oppi session list and use the same timeline, tool rendering, and stored session state as other Oppi sessions.

The terminal Pi process remains the source of truth. Oppi can watch, send prompts, steer the active turn, queue follow-ups, answer supported extension UI, and stop the session, but it does not silently take over execution.

In Oppi clients:

- connected mirror sessions show as `Mirror live`
- disconnected or stale mirror sessions show as `Mirror offline`
- stopped, disconnected mirror sessions can be resumed as managed Oppi sessions when the server has the session file

## What works from mobile

Mirror mode is meant for supervising and steering an active terminal session.

Supported from Oppi:

- prompts
- steer and follow-up messages
- stop or abort
- queue updates
- model and thinking-level changes
- session rename, compaction, and tree navigation
- standard Pi extension UI such as ask, select, confirm, input, editor, notify, title, status, and simple widget text, rendered through the native contract in [`extension-native-ui.md`](extension-native-ui.md)

Still terminal-only:

- creating a new session
- fork and switch-session flows
- terminal-specific custom UI, headers, footers, custom editors, and raw TUI rendering unless the mirror bridge advertises a future native-snapshot capability
- session sharing from a mirrored session

## Known Limitations

- Mirror supports standard semantic Pi extension UI. Custom terminal component trees and raw ANSI/TUI layouts require an explicit bridge-forwarded snapshot or native-snapshot capability; otherwise they remain terminal-owned.
- Session-file replacement commands such as new session, fork, and switch session remain terminal-only.
- Session sharing from a mirrored session is not supported yet.
- Reconnect and stale terminal state still need more real-device soak testing.

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

If the extension cannot find Oppi configuration, start the Oppi server once or set:

```bash
OPPI_MIRROR_URL=...
OPPI_MIRROR_TOKEN=...
```

### The extension starts in the wrong process

Mirror mode only starts from an interactive Pi TUI terminal. It must not run from SDK, print, JSON, or non-interactive processes.

Disable auto-start when needed:

```bash
OPPI_MIRROR_AUTO_START=false pi
```

### The session appears twice

The mirror session and local JSONL import must share the same `piSessionId` and canonical session file. If duplicates appear, check the server’s mirror identity coalescing and local-session import behavior.

