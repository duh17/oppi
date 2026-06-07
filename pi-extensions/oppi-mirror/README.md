# oppi-mirror

`oppi-mirror` is a Pi extension that mirrors an interactive terminal `pi` session into Oppi. The terminal keeps execution ownership; Oppi can watch output, send prompts, steer the active turn, queue follow-ups, answer extension UI, and stop or abort through the bridge.

## Install

```bash
pi install npm:oppi-mirror
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

Configure startup and missing-workspace behavior in `~/.pi/agent/settings.json`:

```json
{
  "oppiMirror": {
    "autoStart": false,
    "workspaceCreation": "ask"
  }
}
```

`workspaceCreation` accepts `ask`, `always`, or `never`. The default is `ask`: if the terminal cwd is not inside an Oppi workspace, Pi prompts before creating one. Approved workspaces use the nearest parent git repo as `hostMount`; without a git repo, they use the terminal cwd.

For one process:

```bash
OPPI_MIRROR_AUTO_START=false \
OPPI_MIRROR_WORKSPACE_CREATION=never \
pi
```

## What it supports

Mirror supports prompts, steer and follow-up messages, stop, queue updates, model and thinking changes, tree navigation, and standard Pi extension UI flows.

Session replacement stays terminal-owned. Use terminal Pi for `/new`, `/fork`, and session switching.

## Requirements

- Oppi server `0.4.0` or newer
- Interactive terminal `pi`; print, JSON, RPC, and server-owned SDK sessions are not mirror sessions

See the full mirror contract and compatibility matrix in the Oppi repo: https://github.com/duh17/oppi/blob/main/docs/oppi-mirror.md
