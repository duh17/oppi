---
name: oppi-stats
description: Workspace session stats — session counts, message counts, cost breakdown per workspace. Use when asked about session usage, costs, or workspace activity.
---

# Oppi Stats

Quick workspace session stats from the Oppi server.

```bash
node {baseDir}/scripts/oppi-stats.mjs
```

Output: per-workspace breakdown of session count, active sessions, messages, cost, and last activity.

Add `--json` for machine-readable output.

## Requirements

- Oppi server running (reads config from `~/.config/oppi/config.json`)
