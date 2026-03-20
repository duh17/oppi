---
name: oppi-stats
description: Oppi server stats — session counts, cost breakdown by model and workspace, active sessions, memory usage. Use when asked about session usage, costs, workspace activity, or model spending.
---

# Oppi Stats

Quick session stats from the Oppi server's `/server/stats` endpoint.

```bash
node {baseDir}/scripts/oppi-stats.mjs
node {baseDir}/scripts/oppi-stats.mjs --range 30
node {baseDir}/scripts/oppi-stats.mjs --range 90
node {baseDir}/scripts/oppi-stats.mjs --json
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--range N` | `7` | Time window in days. Accepts `7`, `30`, or `90`. |
| `--json` | off | Output the raw `/server/stats` response as JSON. |

## Human output

- Header: session count, range, total cost, total tokens
- Memory: heap used/total, RSS
- Model breakdown table: model name, sessions, cost, cost share %
- Workspace breakdown table: workspace name, sessions, cost
- Active sessions list (if any): id, status, model, name (child sessions indented with ↳)

## Requirements

- Oppi server running (reads config from `~/.config/oppi/config.json`)
