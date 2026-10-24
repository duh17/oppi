# Oppi Mirror mode

Oppi Mirror shows an interactive terminal `pi` session in Oppi as a live session. The terminal keeps execution ownership. Through the bridge, Oppi can watch output, send prompts, steer the active turn, queue follow-ups, answer extension UI, and stop or abort. Use it to open the same Pi session in the terminal for hands-on work and in Oppi for mobile viewing and steering.

Mirror works only with interactive terminal Pi. Do not use it for server-owned SDK sessions, `pi -p`, JSON mode, RPC mode, or other non-interactive processes.

## Set up

Prerequisites:

- Oppi server `0.47.0` or newer is running, with its owner-only socket at `$OPPI_DATA_DIR/run/oppi.sock` (normally `~/.config/oppi/run/oppi.sock`).
- You start Pi in an interactive terminal.

Install the extension with Pi's `npm:` source:

```bash
pi install npm:oppi-mirror      # recorded in Pi settings; loads on future launches
pi -e npm:oppi-mirror           # or a one-off run without editing settings
pi update --extension npm:oppi-mirror   # update before upgrading the Oppi server
```

If Pi is already running, run `/reload`. Then start `pi`; the extension connects the terminal session to Oppi automatically.

One command, three actions:

| Command | Effect |
| --- | --- |
| `/oppi-mirror start` | Connects the current interactive Pi session to Oppi |
| `/oppi-mirror stop` | Closes the bridge for this session |
| `/oppi-mirror status` | Reports whether the bridge is connected and shows the Oppi workspace and session IDs |

## Configuration

The extension connects over the owner-only Unix socket, which needs no bearer token. The network listener does not expose `/mirror/v1/bridge`.

```bash
OPPI_MIRROR_SOCKET=/path/to/oppi.sock pi        # a different socket for one process
OPPI_MIRROR_AUTO_START=false pi                 # no auto-start for one process
OPPI_MIRROR_WORKSPACE_CREATION=never pi         # see below
```

A network URL (`OPPI_MIRROR_URL` with `OPPI_MIRROR_TOKEN`) exists only for explicit debugging, and the live server rejects owner-token WSS upgrades on `/mirror/v1/bridge`.

Set startup and missing-workspace behavior in `~/.pi/agent/settings.json`:

```json
{
  "oppiMirror": {
    "autoStart": false,
    "workspaceCreation": "ask"
  }
}
```

`workspaceCreation` is `ask` (the default; terminal Pi prompts before creating a workspace), `always` (create without prompting), or `never`. When creation is approved, Oppi uses the nearest parent git repo as the workspace root, or the terminal cwd when there is none.

## Behavior in Oppi

Mirror sessions appear in the normal session list with the same timeline, tool rendering, and stored session state. The terminal Pi process stays the source of truth; Oppi does not silently take over execution.

- A connected mirror session shows a green, animated terminal icon (VoiceOver: "pi-tui live"). A disconnected or stale one shows a grey terminal icon ("pi-tui offline").
- A stopped, disconnected mirror session can be resumed as a server-owned Oppi session when the server has the session file.

| From Oppi | Terminal only |
| --- | --- |
| Prompts, steer and follow-up messages, stop or abort | Creating a new session |
| Queue updates | Fork and switch-session flows |
| Model and thinking-level changes | Custom UI, headers, footers, custom editors, and raw TUI rendering (unless the bridge forwards a native snapshot) |
| Session rename, compaction, and tree navigation | Session sharing from a mirrored session |
| Standard Pi extension UI ([matrix](#extension-ui-compatibility-matrix)) and Oppi AskCard multi-select (Oppi-specific, with terminal fallback) | |

## Extension UI compatibility matrix

| Pi or Oppi UI request | Mobile behavior | Terminal behavior |
| --- | --- | --- |
| `ctx.ui.select`, `ctx.ui.confirm`, `ctx.ui.input`, `ctx.ui.editor` | Native prompt; the first answer from phone or terminal settles the request | Terminal prompt stays available |
| `ctx.ui.notify`, `ctx.ui.setTitle`, `ctx.ui.setStatus`, `ctx.ui.setWidget` | Native banner, status, or surface when the request is semantic | Terminal-owned |
| `ctx.ui.setWorkingMessage`, `ctx.ui.setWorkingVisible`, `ctx.ui.setWorkingIndicator` | Native working row text, visibility, and indicator | Terminal-owned |
| Oppi AskCard multi-select | Native AskCard; first response wins | Terminal fallback |
| Custom terminal components, headers, footers, raw TUI layouts | Terminal-owned unless bridged as a semantic widget or snapshot | Terminal-owned |

## Troubleshooting

**The bridge does not start.** Run `/oppi-mirror status`. If the extension cannot find the Oppi socket, start the Oppi server once or set `OPPI_MIRROR_SOCKET=/path/to/oppi.sock`.

**The extension starts in the wrong process.** Mirror starts only from an interactive Pi TUI terminal. Disable auto-start with `OPPI_MIRROR_AUTO_START=false pi` when needed.

**The session appears twice.** The mirror session and the local JSONL import must share the same `Session.id` (the Pi session UUID) and session file. If duplicates appear, check the server's mirror identity and local-session import behavior.

**Logs.** Diagnostics are structured JSON lines. Server mirror logs are in `~/.config/oppi/server.log`. Terminal extension logs are in `~/.config/oppi/oppi-mirror-YYYY-MM-DD.log` (UTC daily files, kept 14 days); set `OPPI_MIRROR_LOG_PATH` to a base file path to relocate them (`/tmp/custom.log` writes `/tmp/custom-YYYY-MM-DD.log`). A leftover `oppi-mirror.log` is not the live target. Useful fields: `sessionId`, `workspaceId`, `bridgeId`, `commandId`, `requestId`, `clientTurnId`, `command`, `outcome`, `durationMs`, `queueVersion`, `steeringCount`, and `followUpCount`.
