> Mirror a live terminal Pi TUI session into Oppi.

# Oppi Mirror Extension

The Oppi Mirror extension lets an interactive terminal `pi` TUI session appear as a live Oppi session.

The terminal still owns execution. Oppi clients can observe the session and send prompts, steer messages, follow-ups, and abort requests through the extension bridge.

Use mirror mode when you want to keep working in the terminal while monitoring or steering the same session from Oppi.

Do not use mirror mode for server-owned SDK sessions, print mode, JSON mode, or other non-interactive Pi processes.

## Quick Start

Install the extension with Pi’s package installer:

```bash
pi install ./pi-extensions/oppi-mirror.ts
```

That records the local extension in Pi settings so Pi loads it automatically on startup.

If Pi is already running, reload extensions:

```text
/reload
```

`pi install npm:...` is not available for this extension yet because `oppi-mirror` is not currently published as a Pi package on npm. Right now this repo ships the extension as a local TypeScript file, so the supported install path is local-file installation.

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

The terminal Pi process remains the execution source of truth. Oppi observes and steers that process; it does not replace it.

Mirror mode is modeled as a remote transport for the same AgentSession event/command contract used by managed sessions. Shared server code owns prompt/steer/follow-up delivery, forwarded command handling, timeline messages, session mutation, compaction rows, titles, stats, command results, and queue state. The bridge command driver owns only bridge serialization, command timeouts, and disconnect rejection. In the terminal extension, `MirrorQueueProjection` makes Pi's queue snapshot authoritative while preserving Oppi item IDs and image metadata for iOS.

In Oppi clients:

- connected mirror sessions show as `Mirror live`
- disconnected or stale mirror sessions show as `Mirror offline`
- terminal-only extension status messages are not rendered as iOS chat cards
- connected or stale mirror sessions remain terminal-owned; Oppi does not silently take over execution
- stopped, disconnected mirror sessions can be explicitly resumed as managed Oppi sessions when the server has a canonical `piSessionFile`

## Remote Command Support Matrix

Mirror mode intentionally supports only commands that can run safely against a terminal-owned Pi session. Commands that replace the session file remain terminal-owned because running them remotely would make the terminal UI context stale.

| Command                 | Server-owned sessions | Mirror sessions  | Notes                                                                                                                                                |
| ----------------------- | --------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prompt`                | Supported             | Supported        | Mirrored exact `/reload` is routed to terminal reload instead of starting a turn.                                                                    |
| `steer`                 | Supported             | Supported        | Requires an active streaming turn.                                                                                                                   |
| `follow_up`             | Supported             | Supported        | Requires an active streaming turn.                                                                                                                   |
| `abort` / `stop`        | Supported             | Supported        | Aborts the current turn; mirror keeps queued phone messages instead of dropping them.                                                                |
| `stop_session`          | Supported             | Supported        | Sends `stop` to the terminal bridge and waits for terminal shutdown. Offline sessions must still be stopped from the terminal.                       |
| `get_state`             | Supported             | Supported        | Mirror state comes from bridge heartbeats and command snapshots.                                                                                     |
| `get_messages`          | Supported             | Supported        | Mirror returns terminal session entries.                                                                                                             |
| `get_session_stats`     | Supported             | Supported        | Mirror includes session file, Pi session ID, entry count, and context usage.                                                                         |
| `get_queue`             | Supported             | Supported        | Bridge result must include a valid queue state.                                                                                                      |
| `set_queue`             | Supported             | Supported        | Uses queue version checks; terminal applies the replacement.                                                                                         |
| `set_model`             | Supported             | Supported        | Fails if terminal Pi has no key/model for the requested provider/model.                                                                              |
| `cycle_model`           | Supported             | Supported        | Cycles in the terminal Pi process.                                                                                                                   |
| `get_available_models`  | Supported             | Supported        | Uses terminal model registry for mirror sessions.                                                                                                    |
| `set_thinking_level`    | Supported             | Supported        | Applied in the terminal Pi process.                                                                                                                  |
| `cycle_thinking_level`  | Supported             | Supported        | Applied in the terminal Pi process.                                                                                                                  |
| `reload`                | Supported             | Supported        | Terminal reload disconnects are treated as transient.                                                                                                |
| `new_session`           | Supported             | Unsupported      | Session replacement is terminal-owned. Use the terminal UI.                                                                                          |
| `set_session_name`      | Supported             | Supported        | Name is projected back into Oppi state.                                                                                                              |
| `compact`               | Supported             | Supported        | Runs terminal compaction and forwards compaction events.                                                                                             |
| `set_auto_compaction`   | Supported             | Supported        | Applied to the terminal `AgentSession`.                                                                                                              |
| `fork`                  | Supported             | Unsupported      | Session-file replacement is terminal-owned. Use the terminal UI.                                                                                     |
| `get_fork_messages`     | Supported             | Supported        | Uses terminal `AgentSession.getUserMessagesForForking()`.                                                                                            |
| `get_session_tree`      | Supported             | Supported        | Bridge serializes Pi's session tree into the same mobile outline snapshot shape.                                                                     |
| `navigate_tree`         | Supported             | Supported        | Safe because it stays in the same session file.                                                                                                      |
| `switch_session`        | Supported             | Unsupported      | Session-file replacement is terminal-owned. Use the terminal UI.                                                                                     |
| `set_steering_mode`     | Supported             | Supported        | Applied to the terminal `AgentSession`.                                                                                                              |
| `set_follow_up_mode`    | Supported             | Supported        | Applied to the terminal `AgentSession`.                                                                                                              |
| `set_auto_retry`        | Supported             | Supported        | Applied to the terminal `AgentSession`.                                                                                                              |
| `abort_retry`           | Supported             | Supported        | Calls terminal retry abort.                                                                                                                          |
| `abort_bash`            | Supported             | Supported        | Calls terminal bash abort.                                                                                                                           |
| `get_commands`          | Supported             | Supported        | Returns terminal slash commands for mirror sessions.                                                                                                 |
| `share_session`         | Supported             | Unsupported      | Should be supported, but needs the server share pipeline wired to a mirrored session file instead of a live server-owned `AgentSession`.             |
| `extension_ui_response` | Supported             | Supported        | Routes mobile answers for `ask`, `select`, `confirm`, `input`, and `editor` back to the terminal bridge; terminal and phone answers race first-wins. |
| `dictation_*`           | Dedicated stream      | Dedicated stream | Not handled on the session command path.                                                                                                             |

Unsupported mirror commands fall into a few concrete buckets:

- `new_session`, `fork`, and `switch_session` replace the terminal session file. Pi invalidates the old extension context during replacement and continues in a fresh session context, so a remote implementation needs an explicit product choice: mutate the visible terminal session from the phone, or create a separate Oppi-owned session. For v1, keep those actions in the terminal UI; mobile can use the dedicated fork-into-new-Oppi-session flow when it needs a separate session.
- `share_session` uses the server-owned session export, redaction, scanning, and publish pipeline. It should be supported for mirror sessions, but the right implementation is server-side sharing from the mirrored session file, not forwarding share work into the terminal bridge.

When changing this matrix, update the matching implementation path:

1. Forwarded bridge commands: `server/src/pi-tui-mirror-runtime.ts` command allowlist / unsupported reasons and `pi-extensions/oppi-mirror.ts` command handlers.
2. Transport-special commands such as prompt, steer, follow-up, abort, stop-session, queue, and extension UI responses: the `AgentRuntimeCommandTransport` implementation, WebSocket handler, and bridge message handling as applicable.
3. This documentation and the mirror tests.

## Extension UI Compatibility Matrix

Mirror mode maps Pi's RPC-style extension UI protocol onto native Oppi UI. It does not execute terminal renderers on iOS.

| Pi/TUI surface                                                                                                 | Mobile mirror behavior                                                                                            | Status                                  | Reason / constraint                                                          |
| -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------- |
| Tool `content` and `details`                                                                                   | Rendered through native timeline rows, mobile renderers, markdown/diff/code parsing, and generic expanded output. | Supported                               | This is data, not terminal layout.                                           |
| Tool `renderCall()` / `renderResult()`                                                                         | Not executed by iOS. Oppi uses native rows and optional mobile renderer sidecars.                                 | Unsupported directly                    | TUI components depend on terminal width, ANSI styling, and keyboard focus.   |
| Oppi ask extension (`method: "ask"`)                                                                           | Presented as the native ask card; answers return through `extension_ui_response.value`.                           | Supported                               | Reuses the first-class ask lifecycle and attention handling.                 |
| `ctx.ui.select()`                                                                                              | Presented as a native single-choice card or sheet.                                                                | Supported                               | Mobile returns the selected option string or cancellation.                   |
| `ctx.ui.confirm()`                                                                                             | Presented as a native confirmation card or sheet.                                                                 | Supported                               | Mobile returns `confirmed: true` or cancellation.                            |
| `ctx.ui.input()`                                                                                               | Presented as a native text input.                                                                                 | Supported                               | Mobile returns the submitted string or cancellation.                         |
| `ctx.ui.editor()`                                                                                              | Presented as a native multi-line editor sheet.                                                                    | Supported                               | Mobile returns edited text or cancellation.                                  |
| `ctx.ui.notify()`                                                                                              | Forwarded as an Oppi notification/toast surface.                                                                  | Supported                               | Fire-and-forget; no response expected.                                       |
| `ctx.ui.setTitle()`                                                                                            | Forwarded to the native extension surface title.                                                                  | Supported                               | It does not change the iOS navigation title directly.                        |
| `ctx.ui.setStatus()`                                                                                           | Forwarded to the native extension surface. The `oppi-mirror` status key is suppressed on iOS.                     | Supported with filtering                | Mirror's terminal-only status indicator would be duplicate chrome on mobile. |
| `ctx.ui.setWidget()` with string lines                                                                         | Forwarded as native monospaced widget lines.                                                                      | Supported with text-only input          | Component factories are terminal-only.                                       |
| `ctx.ui.setEditorText()` / `pasteToEditor()`                                                                   | Forwarded as composer text handoff.                                                                               | Supported with degraded paste semantics | Mobile does not emulate terminal paste collapse or editor replacement.       |
| `ctx.ui.custom()` and overlays                                                                                 | Not rendered on mobile.                                                                                           | Unsupported                             | They require terminal component trees and keyboard focus.                    |
| `setHeader`, `setFooter`, `setEditorComponent`, `setWorkingMessage`, `setWorkingIndicator`, `setToolsExpanded` | Not mirrored to mobile UI.                                                                                        | Unsupported                             | These are terminal chrome controls, not portable app UI.                     |
| Theme APIs and raw ANSI/TUI styling                                                                            | Ignored by mobile.                                                                                                | Unsupported                             | Mobile uses semantic Oppi theme tokens and native controls.                  |

### Extension UI race resolution

Dialog requests can be answered from either the terminal or Oppi mobile:

1. The extension opens the terminal dialog and sends an `extension_ui_request` with a unique `id` to the bridge.
2. The terminal dialog promise and the phone response promise race.
3. If the phone wins, the bridge returns that value to the extension and aborts the local terminal dialog when the dialog supports an abort signal.
4. If the terminal wins, the bridge sends `extension_ui_request_settled`; the server broadcasts `extension_ui_settled` so mobile clears stale UI.
5. Late duplicate responses are ignored because the pending request is removed after the first settlement.

Pending non-ask dialogs are replayed to mobile on stream reconnect. Ask requests use the ask store and are replayed through the first-class ask path instead.

## Queue Behavior

The terminal Pi process owns the message queue.

Oppi can forward:

- immediate prompts
- steer messages
- follow-up messages
- image attachments

The bridge reports queue state and can apply queue replacements through the terminal `AgentSession`. `MirrorQueueProjection` is only a projection layer: it reconciles from Pi's queue snapshot, preserves Oppi queue item IDs and image metadata, and drops stale items when the terminal queue shrinks or clears. This currently uses Pi queue internals, so keep queue behavior covered by mirror tests and prefer a public Pi queue replacement API when one exists.

Oppi must not create a separate source-of-truth editable queue model for mirrored sessions. The terminal queue remains authoritative.

## Race and Stale-State Resolution

Mirror mode uses terminal ownership plus bounded reconciliation rather than split-brain state:

- **Bridge ownership:** one live bridge owns a mirrored session. A newer bridge for the same session replaces the older connection.
- **Execution ownership:** connected and stale mirror sessions stay terminal-owned; Oppi does not take over unless the user explicitly resumes a stopped, disconnected mirror session.
- **Command correlation:** mobile uses `requestId`; the server bridge uses `commandId`; every supported remote command returns a correlated `command_result` success or failure.
- **Unsupported commands:** mirror rejects unsupported commands before sending anything to the terminal and returns a `command_result` failure with the unsupported reason.
- **Turn dedupe:** prompt/steer/follow-up sends carry `clientTurnId` so replayed client requests do not duplicate accepted turns.
- **Queue edits:** `set_queue` uses `baseVersion`; stale mobile replacements fail instead of overwriting the terminal queue.
- **Queue convergence:** `queue_update`, `queue_state`, and `queue_item_started` reconcile the native mobile queue projection back to Pi's queue.
- **Extension UI:** dialog races are first-wins and idempotent, as described above.
- **Reloads and restarts:** `/reload` is routed to terminal reload. Server restarts disconnect bridges; the extension reconnects and re-registers the same Pi session identity.

## Session Identity

Mirror sessions use the same Pi identity fields as local JSONL imports:

- `piSessionId`
- canonical `piSessionFile`
- `piSessionFiles[]`

This prevents the same terminal session from appearing twice: once as a live mirror session and once as an importable local JSONL session.

Session rows ignore generic Pi names such as `Session <id>` so they can fall back to the first real user message.

## Health and Telemetry

For v1, mirror health is log-first, with generic client/server metrics for latency and queue UX.

| Health question                | Source                                                                                                                                                                                                                            | Good signal                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Is the bridge connected?       | `~/.config/oppi/server.log` events `mirror_bridge.connected` / `mirror_bridge.disconnected`; `~/.config/oppi/oppi-mirror.log` events `bridge_connected` / `bridge_disconnected`.                                                  | Connected bridge has matching `sessionId`, `workspaceId`, `bridgeId`, and a recent `lastSeenAt`.             |
| Are remote commands working?   | Server `mirror_bridge.command_sent` / `mirror_bridge.command_result`; extension `command_received` / `command_completed`.                                                                                                         | Correlated `commandId`, `outcome: "success"`, low `durationMs`, and no pending-command count on disconnect.  |
| Is queue state converging?     | Extension `queue_projection_reconciled`; server `mirror_bridge.queue_state_applied`; WebSocket `ws.queue_command.completed`.                                                                                                      | Monotonic `queueVersion`; `steeringCount` and `followUpCount` match the mobile UI after refresh.             |
| Are extension dialogs healthy? | Server ops metrics for `server.ws_message_sent` with `type=extension_ui_request` / `extension_ui_settled` and `server.ws_message_received` with `type=extension_ui_response`; client command metrics for `extension_ui_response`. | Each dialog request has one response or settlement; stale mobile dialogs clear after `extension_ui_settled`. |
| Does mobile feel responsive?   | Client metrics `chat.command_roundtrip_ms`, `chat.queue_sync_ms`, `chat.message_queue_ack_ms`, and timeline render metrics.                                                                                                       | Errors are rare; slow samples correlate to server logs by `sessionId` and `requestId`.                       |

Useful review commands:

```bash
cd server
npm run telemetry:server-log -- --days 1 --limit 30
rg -n 'mirror_bridge|bridge_connected|bridge_disconnected|extension_ui|oppi-mirror' \
  ~/.config/oppi/server.log ~/.config/oppi/oppi-mirror.log
```

Current limitation: client command metrics do not directly label mirror sessions. Use `sessionId`, `bridgeId`, and the mirror log events to isolate mirror sessions. Add a bounded mirror tag if mirror command latency becomes a release-gate metric.

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

## Known Limitations

- Extension UI v1 supports ask/select/confirm/input/editor and fire-and-forget notify/title/status/widget/editor-text. Custom TUI components, headers, footers, custom editors, working indicators, tool renderers, raw ANSI layouts, and theme switching remain terminal-only.
- Permission gates should use Pi extension UI (`ctx.ui`) or ask flows. Oppi no longer has a custom approval-response protocol path.
- Queue editing currently relies on Pi terminal queue internals until Pi exposes a stable public queue replacement API.
- Session-file replacement commands (`new_session`, `fork`, `switch_session`) remain terminal-only until the product semantics are explicit.
- Session sharing (`share_session`) still needs server-side sharing from a mirrored session file.
- Explicit resume as managed is only available after the mirror session is stopped, disconnected, and has a canonical session file.
- Mirror-specific health is currently log-first; generic client command metrics do not directly label mirror sessions.
- Reconnect and stale terminal state need continued real-device soak testing.

## Maintainer Notes

Mirror mode is a transport adapter, not a second session implementation.

Shared projection code owns:

- Pi event translation to `ServerMessage`
- session state mutation from Pi events
- tool-media materialization
- first-message and title derivation
- session summaries and SQLite projection

The mirror bridge owns only bridge-specific behavior:

- terminal bridge registration
- reconnect and stale state
- remote command serialization and timeouts
- terminal-owned queue observation

Do not copy managed session projection logic into the mirror bridge. If a change affects Pi event translation, session mutation, tool media, titles, or summaries, put it in shared projection code and add mirror/managed parity coverage.
