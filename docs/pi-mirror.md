> Mirror a live terminal Pi TUI session into Oppi.

# Oppi Pi Mirror Extension

The Oppi Pi Mirror extension lets an interactive terminal `pi` TUI session appear as a live Oppi session.

The terminal still owns execution. Oppi clients can observe the session and send prompts, steer messages, follow-ups, and abort requests through the extension bridge.

Use mirror mode when you want to keep working in the terminal while monitoring or steering the same session from Oppi.

Do not use mirror mode for server-owned SDK sessions, print mode, JSON mode, or other non-interactive Pi processes.

## Quick Start

Install the extension with Pi’s package installer:

```bash
pi install ./pi-extensions/oppi-pi-mirror.ts
```

That records the local extension in Pi settings so Pi loads it automatically on startup.

If Pi is already running, reload extensions:

```text
/reload
```

`pi install npm:...` is not available for this extension yet because `oppi-pi-mirror` is not currently published as a Pi package on npm. Right now this repo ships the extension as a local TypeScript file, so the supported install path is local-file installation.

Start the Oppi server once so the extension can discover the local server URL and token from:

```text
~/.config/oppi/config.json
```

Then start Pi in an interactive terminal:

```bash
pi
```

The extension starts automatically and connects the terminal session to Oppi.

Check the bridge status from Pi:

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

Override the connection with environment variables:

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

The extension adds one Pi command:

```text
/oppi-mirror start
/oppi-mirror stop
/oppi-mirror status
```

`start` connects the current interactive Pi TUI session to Oppi.

`stop` closes the bridge for the current session.

`status` reports whether the bridge is connected and, when available, shows the Oppi workspace and session IDs.

## Behavior

Mirror mode uses the same Oppi session projection as managed Pi sessions. Mirrored sessions appear in the normal Oppi session list and use the same chat timeline, tool rendering, summaries, and stored session state.

The terminal Pi process remains the execution source of truth. Oppi observes and steers the terminal runtime; it does not replace it.

Mirror mode is modeled as a remote transport for the same AgentSession event/command contract used by managed sessions. On the server, `server/src/agent-runtime-transport.ts` defines the runtime contract, `server/src/session-input.ts` owns shared prompt/steer/follow-up delivery policy, and `server/src/runtime-command-coordinator.ts` owns forwarded-command orchestration shared by managed and mirror runtimes. `server/src/mirror-bridge-command-driver.ts` owns only bridge command serialization, pending-command timeouts, and disconnect rejection. In the terminal extension, `MirrorQueueProjection` makes Pi's runtime queue snapshot authoritative while preserving Oppi item IDs and image metadata for iOS. The bridge should forward canonical `AgentSessionEvent` payloads and execute canonical commands; shared server projection code owns timeline messages, session mutation, compaction rows, titles, stats, command results, and queue state.

Mirror sessions use:

```text
runtime == "pi-tui-mirror"
```

In Oppi clients:

- connected mirror sessions show as `Mirror live`
- disconnected or stale mirror sessions show as `Mirror offline`
- terminal-only extension status messages are not rendered as iOS chat cards
- disconnected mirror sessions remain terminal-owned; Oppi does not silently promote them into managed SDK sessions

## Remote Command Support Matrix

Mirror mode intentionally supports only commands that can run safely against a terminal-owned Pi session. Commands that replace the session file remain terminal-owned because running them remotely would make the terminal UI context stale.

| Command                 | Managed SDK runtime | Terminal mirror runtime | Notes                                                                                     |
| ----------------------- | ------------------- | ----------------------- | ----------------------------------------------------------------------------------------- |
| `prompt`                | Supported           | Supported               | Mirrored exact `/reload` is routed to terminal reload instead of starting a turn.         |
| `steer`                 | Supported           | Supported               | Requires an active streaming turn.                                                        |
| `follow_up`             | Supported           | Supported               | Requires an active streaming turn.                                                        |
| `abort` / `stop`        | Supported           | Supported               | Aborts the current turn; mirror keeps queued phone messages instead of dropping them.     |
| `stop_session`          | Supported           | Unsupported             | Mirror sessions must be stopped from the terminal.                                        |
| `get_state`             | Supported           | Supported               | Mirror state comes from bridge heartbeats and command snapshots.                          |
| `get_messages`          | Supported           | Supported               | Mirror returns terminal session entries.                                                  |
| `get_session_stats`     | Supported           | Supported               | Mirror includes session file, Pi session ID, entry count, and context usage.              |
| `get_queue`             | Supported           | Supported               | Bridge result must include a valid queue state.                                           |
| `set_queue`             | Supported           | Supported               | Uses queue version checks; terminal applies the replacement.                              |
| `set_model`             | Supported           | Supported               | Fails if terminal Pi has no key/model for the requested provider/model.                   |
| `cycle_model`           | Supported           | Supported               | Cycles in the terminal runtime.                                                           |
| `get_available_models`  | Supported           | Supported               | Uses terminal model registry for mirror sessions.                                         |
| `set_thinking_level`    | Supported           | Supported               | Applied in the terminal runtime.                                                          |
| `cycle_thinking_level`  | Supported           | Supported               | Applied in the terminal runtime.                                                          |
| `reload`                | Supported           | Supported               | Terminal reload disconnects are treated as transient.                                     |
| `new_session`           | Supported           | Unsupported             | Session replacement is terminal-owned. Use the terminal UI.                               |
| `set_session_name`      | Supported           | Supported               | Name is projected back into Oppi state.                                                   |
| `compact`               | Supported           | Supported               | Runs terminal compaction and forwards compaction events.                                  |
| `set_auto_compaction`   | Supported           | Supported               | Applied to the terminal `AgentSession`.                                                   |
| `fork`                  | Supported           | Unsupported             | Session-file replacement is terminal-owned. Use the terminal UI.                          |
| `get_fork_messages`     | Supported           | Supported               | Uses terminal `AgentSession.getUserMessagesForForking()`.                                 |
| `get_session_tree`      | Supported           | Unsupported             | The bridge does not expose Pi's tree serializer yet.                                      |
| `navigate_tree`         | Supported           | Supported               | Safe because it stays in the same session file.                                           |
| `switch_session`        | Supported           | Unsupported             | Session-file replacement is terminal-owned. Use the terminal UI.                          |
| `set_steering_mode`     | Supported           | Supported               | Applied to the terminal `AgentSession`.                                                   |
| `set_follow_up_mode`    | Supported           | Supported               | Applied to the terminal `AgentSession`.                                                   |
| `set_auto_retry`        | Supported           | Supported               | Applied to the terminal `AgentSession`.                                                   |
| `abort_retry`           | Supported           | Supported               | Calls terminal retry abort.                                                               |
| `abort_bash`            | Supported           | Supported               | Calls terminal bash abort.                                                                |
| `get_commands`          | Supported           | Supported               | Returns terminal slash commands for mirror sessions.                                      |
| `share_session`         | Supported           | Unsupported             | Sharing needs a server-owned `AgentSession` export path.                                  |
| `permission_response`   | Supported           | Not complete            | Remote approval/tool gate policy for terminal-owned sessions is still a product decision. |
| `extension_ui_response` | Supported           | Not complete            | Extension UI request routing is not wired for terminal-owned sessions.                    |
| `dictation_*`           | Dedicated stream    | Dedicated stream        | Not handled on the session command path.                                                  |

When changing this matrix, update all three places together:

1. `server/src/pi-tui-mirror-runtime.ts` command allowlist and unsupported reasons.
2. `pi-extensions/oppi-pi-mirror.ts` bridge command handlers.
3. This documentation and the mirror runtime tests.

## Queue Behavior

The terminal Pi runtime owns the message queue.

Oppi can forward:

- immediate prompts
- steer messages
- follow-up messages
- image attachments

The bridge reports queue state and can apply queue replacements through the terminal `AgentSession`. `MirrorQueueProjection` is only a projection layer: it reconciles from Pi's runtime queue snapshot, preserves Oppi queue item IDs and image metadata, and drops stale items when the terminal queue shrinks or clears. This currently uses Pi runtime internals, so keep queue behavior covered by mirror tests and prefer a public Pi queue replacement API when one exists.

Oppi must not create a separate source-of-truth editable queue model for mirrored sessions. The terminal queue remains authoritative.

## Session Identity

Mirror sessions use the same Pi identity fields as local JSONL imports:

- `piSessionId`
- canonical `piSessionFile`
- `piSessionFiles[]`

This prevents the same terminal session from appearing twice: once as a live mirror session and once as an importable local JSONL session.

Session rows ignore generic Pi names such as `Session <id>` so they can fall back to the first real user message.

## Troubleshooting

### Debug logs

Mirror diagnostics are structured JSON lines.

- Server mirror/runtime logs: `~/.config/oppi/server.log`
- Terminal extension logs: `~/.config/oppi/pi-mirror.log`

Useful fields: `runtime`, `sessionId`, `bridgeId`, `commandId`, `requestId`, `clientTurnId`, `command`, `outcome`, `durationMs`, `queueVersion`, `steeringCount`, and `followUpCount`. Managed-session server logs use `runtime: "managed"`; mirrored-session logs use `runtime: "pi-tui-mirror"`.

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

## Known Limitations

- Ask and extension UI compatibility is not complete for terminal-owned sessions.
- Remote approval and tool-call gates still need a mirror-specific product decision.
- Queue editing currently relies on Pi terminal runtime internals until Pi exposes a stable public queue replacement API.
- Session-file replacement commands (`new_session`, `fork`, `switch_session`) remain terminal-only.
- Explicit "resume this mirror as managed" is not implemented yet; disconnected mirror sessions stay mirror-owned.
- Reconnect and stale terminal state need continued real-device soak testing.

## Maintainer Notes

Mirror mode is a runtime adapter, not a second session implementation.

Shared projection code owns:

- Pi event translation to `ServerMessage`
- session state mutation from Pi events
- tool-media materialization
- first-message and title derivation
- session summaries and SQLite projection

The mirror runtime owns only bridge-specific behavior:

- terminal bridge registration
- reconnect and stale state
- remote command serialization and timeouts
- terminal-owned queue observation

Do not copy managed session projection logic into the mirror runtime. If a change affects Pi event translation, session mutation, tool media, titles, or summaries, put it in shared projection code and add mirror/managed parity coverage.
