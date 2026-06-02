# oppi-mirror

`oppi-mirror` is a Pi extension that mirrors an interactive terminal `pi` session into Oppi. The terminal keeps execution ownership; Oppi can watch output, send prompts, steer the active turn, queue follow-ups, answer extension UI, and stop or abort through the bridge.

## Install

```bash
pi install npm:oppi-mirror
```

Use `npm:oppi-mirror@0.4.0` only when you want to pin a specific release; pinned package specs are skipped by `pi update`.

For local development from an Oppi checkout:

```bash
pi install ./pi-extensions/oppi-mirror
# or one run only:
pi -e ./pi-extensions/oppi-mirror
```

If local package loading reports a missing runtime dependency, install package dependencies once:

```bash
cd pi-extensions/oppi-mirror && npm install
```

If Pi is already running, reload extensions:

```text
/reload
```

## Use

Start the Oppi server once so the extension can read `~/.config/oppi/config.json`, then start Pi in an interactive terminal:

```bash
pi
```

Check or control the bridge from Pi:

```text
/oppi-mirror status
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

## Compatibility

Mirror supports terminal-owned prompt, steer, follow-up, stop, queue, model, thinking, compaction, tree navigation, command-list, and standard Pi extension UI flows. Session-file replacement remains terminal-owned: use terminal Pi for `/new`, `/fork`, and `/resume`/switch.

Mirror forwards Pi-native extension UI from terminal sessions. For example, a `tool_call` handler can ask through `ctx.ui.confirm()` or an `ask` flow, and Oppi renders the response path natively.

## Requirements

- Oppi server `0.4.0` or newer
- Interactive terminal `pi`; print, JSON, RPC, and server-owned SDK sessions are not mirror sessions

See the full mirror contract in the Oppi repo: https://github.com/duh17/oppi/blob/main/docs/oppi-mirror.md
