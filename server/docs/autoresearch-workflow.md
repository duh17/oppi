# Autoresearch Workflow

End-to-end guide for running autonomous optimization loops on oppi.

## Architecture

```
Production Metrics                    Synthetic Benchmarks
─────────────────                    ────────────────────
iOS chat metrics ─┐                  server/bench/*.bench.mjs ─── METRIC lines
Server ops metrics┤                  OppiTests/Perf/*.swift   ─── METRIC lines
MetricKit payloads┤                           │
        │         │                           ▼
        ▼         │                   autoresearch.sh
JSONL telemetry ──┘                   autoresearch.checks.sh
        │                             autoresearch.md
        ▼                                    │
telemetry-import-sqlite.mjs                  ▼
        │                             autoresearch loop
        ▼                             (init_experiment → run_experiment → log_experiment)
telemetry.db (SQLite)                        │
        │                                    ▼
        ├──▶ Grafana dashboards       autoresearch.jsonl
        └──▶ telemetry-review.mjs     git log (kept commits)
```

## Quick Start

### 1. Identify the target

Look at Grafana or run telemetry-review to spot what needs optimization:

```bash
node server/scripts/telemetry-review.mjs --days 7
```

Metrics over SLO reference thresholds are flagged. Common targets:
- `chat.ttft_ms` — time to first token (iOS + server)
- `chat.session_load_ms` — session load time (iOS)
- `server.turn_duration_ms` — agent turn processing (server)
- `server.session_subscribe_ms` — subscribe flow (server)

### 2. Choose server or iOS

| Target | Benchmarks | Checks | Templates |
|--------|-----------|--------|-----------|
| Server (Node.js) | `server/bench/*.bench.mjs` | `npm run check` + `vitest run` | `templates/server-autoresearch.*` |
| iOS (Swift) | `OppiTests/Perf/*.swift` | `xcodebuild build` + `test` | `templates/ios-autoresearch.*` |

### 3. Set up the autoresearch session

```bash
# Create worktree (keeps main checkout clean)
BRANCH=autoresearch/optimize-event-ring-$(date +%Y%m%d)
WORKTREE="../oppi-autoresearch/$BRANCH"
git worktree add -b "$BRANCH" "$WORKTREE"
cd "$WORKTREE"

# Symlink gitignored dirs
bash clients/apple/scripts/prepare-worktree.sh "$WORKTREE"

# Copy templates
cp server/skills/autoresearch/templates/server-autoresearch.md autoresearch.md
cp server/skills/autoresearch/templates/server-autoresearch.sh autoresearch.sh
cp server/skills/autoresearch/templates/server-autoresearch-checks.sh autoresearch.checks.sh
chmod +x autoresearch.sh autoresearch.checks.sh

# Fill in the template, then commit
git add autoresearch.md autoresearch.sh autoresearch.checks.sh
git commit -m "chore: set up autoresearch for event-ring optimization"
```

### 4. Run the loop

Tell the agent: "run autoresearch" and it will read `autoresearch.md`, understand the setup, and start the loop.

## Writing Benchmarks

### Server benchmarks

Each benchmark is a standalone `.mjs` file in `server/bench/` that imports from `../dist/` and uses `bench-utils.mjs`:

```js
#!/usr/bin/env node
import { bench } from "./bench-utils.mjs";
import { EventRing } from "../dist/event-ring.js";

// Setup (not timed)
const ring = new EventRing(500);

await bench("event_ring_push", () => {
  // ... operation to time
}, { iterations: 1000 });
```

Run individually: `node server/bench/event-ring.bench.mjs`
Run all: `bash server/scripts/run-bench.sh`

### iOS benchmarks

Swift Testing tests in `OppiTests/Perf/` that print `METRIC` lines:

```swift
@Suite("MyBench")
struct MyBench {
    @MainActor @Test func primary_metric() {
        // warmup + measure, then:
        print("METRIC my_metric_p50_us=\(median)")
        print("METRIC my_metric_p95_us=\(p95)")
    }
}
```

Run via:
```bash
./scripts/sim-pool.sh run -- xcodebuild test \
  -only-testing:'OppiTests/MyBench/primary_metric()()' 2>&1 | grep "^METRIC "
```

## Output Format

All benchmarks output lines matching:
```
METRIC <name>=<number>
```

The autoresearch loop parses these to extract the primary metric and secondary metrics.

## Connecting Production to Benchmarks

### Baseline from production

Use `telemetry-review.mjs --metrics` to extract current production baselines as METRIC lines:

```bash
node server/scripts/telemetry-review.mjs --days 7 --metrics
# METRIC chat.ttft_ms_p50=2341
# METRIC chat.ttft_ms_p95=8234
# METRIC chat.session_load_ms_p50=89
# ...
```

These give you real-world numbers to compare against synthetic benchmarks.

### Post-optimization validation

After autoresearch converges, deploy the changes and monitor the same metrics in Grafana:
1. Deploy to production
2. Wait for telemetry data to accumulate (24h minimum)
3. Run `telemetry-review.mjs --days 1` and compare against pre-optimization baseline
4. Check Grafana Release Preflight dashboard for build-over-build comparison

## Available Benchmarks

### Server

| File | Hot Path | Primary Metric |
|------|---------|----------------|
| `bench/event-ring.bench.mjs` | EventRing push/since | `event_ring_push_p50_us` |
| `bench/ansi.bench.mjs` | ANSI escape stripping | `ansi_strip_mixed_p50_us` |

### iOS

| File | Hot Path | Primary Metric |
|------|---------|----------------|
| `OppiTests/Perf/TimelineLifecycleBench.swift` | Full session lifecycle | `lifecycle_score` |
| `OppiTests/Perf/RenderStrategyPerfTests.swift` | Render strategy | various |
| `OppiTests/Perf/MarkdownParsePerfBench.swift` | Markdown parsing | various |
| `OppiTests/Perf/DiffBuilderPerfBench.swift` | Diff builder | various |
| `OppiTests/Perf/ScrollStabilityBench.swift` | Scroll stability | various |

## Grafana Dashboards

- **Server Health** (`oppi-server-health`): CPU, memory, WS, sessions — operational monitoring
- **Release Preflight** (`oppi-release-preflight`): TTFT, jank, session load, voice — performance regressions

Both read from `telemetry.db` via the `frser-sqlite-datasource` plugin.

## Pipeline Reference

```
JSONL files (server writes)
    │
    ▼
telemetry-import-sqlite.mjs (Docker container, watch mode, 15s interval)
    │
    ▼
telemetry.db (SQLite, 30-day retention)
    │
    ├──▶ Grafana (frser-sqlite-datasource, dashboards in docker/grafana/dashboards/)
    └──▶ telemetry-review.mjs (CLI, SLO checking, gate mode for CI)
```

Docker compose: `server/docker-compose.telemetry.yml`

After changing `telemetry-import-sqlite.mjs`, restart the importer container:
```bash
docker compose -f server/docker-compose.telemetry.yml restart telemetry-importer
```
