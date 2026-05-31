# Telemetry and diagnostics

Oppi records diagnostics to answer one question: **does the app feel fast, reliable, and safe while someone is supervising a Pi session from Apple clients?**

This page is the public source of truth for what telemetry exists, how it is gated, where it is stored, and which metrics matter for user experience.

## Scope

This page covers:

- Apple client diagnostics: MetricKit payloads, chat/runtime metrics, device resource samples, and redacted client logs.
- Server diagnostics: operational metrics, resource samples, and review commands.
- Privacy gates and storage paths.
- The small set of experience metrics that belong on release and quality dashboards.

This page does not cover:

- Pi’s own anonymous install/update telemetry. See Pi documentation for that behavior.
- Provider billing or model-side observability outside Oppi.
- Raw session content review. Oppi can inspect Pi session files locally, but telemetry uploads must not contain prompt text, assistant output, tool arguments, or dictation transcript content.

## Quick review commands

From `server/`:

```bash
npm run telemetry:review -- --days 1 --wide
npm run telemetry:client-logs -- --days 1 --limit 30
npm run telemetry:client-logs -- --hours 3 --limit 30
npm run telemetry:metrickit -- --days 14 --limit 50
npm run telemetry:server-log -- --days 1 --limit 30
npm run diagnostics:review -- --days 1
```

For a release gate:

```bash
npm run telemetry:review:gate
```

For local Grafana:

```bash
npm run telemetry:grafana:up
# Open http://localhost:13001, default login admin/admin
```

## Privacy model

Oppi diagnostics are designed for self-hosted debugging.

- Public iOS release builds set `OPPI_TELEMETRY_MODE=public`.
- Public iOS release builds do not upload diagnostics unless the user enables **Settings → Diagnostics → Send Diagnostics to Server**.
- Public iOS release builds do not start Sentry, even when the diagnostics toggle is enabled.
- Internal/debug builds set `OPPI_TELEMETRY_MODE=internal` and upload diagnostics automatically to the configured Oppi server.
- The server also enforces `OPPI_TELEMETRY_MODE`: `public`, `release`, `prod`, `off`, and equivalent values reject telemetry uploads with HTTP 403.

Telemetry must not include:

- prompt text
- assistant output
- tool arguments
- command output content
- dictation transcript text
- raw URLs, LAN IPs, local file paths, tokens, secrets, or credentials

Allowed diagnostic data:

- low-cardinality IDs such as session ID, workspace ID, app instance ID, and boot ID
- low-cardinality tags such as `transport=lan`, `status=ok`, `error_kind=network`, or `tool=bash`
- numeric timings, counts, ratios, byte counts, and resource samples
- sanitized MetricKit summaries and crash diagnostics
- redacted client log breadcrumbs

## Upload channels

| Channel | Endpoint | Stored at | Purpose |
|---|---|---|---|
| Chat metrics | `POST /telemetry/chat-metrics` | `<OPPI_DATA_DIR>/diagnostics/telemetry/chat-metrics-YYYY-MM-DD.jsonl` | Client UX, rendering, queueing, dictation, and device metrics. |
| MetricKit | `POST /telemetry/metrickit` | `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl` | Apple crash, hang, CPU, disk, and battery diagnostics. |
| Client logs | `POST /telemetry/client-logs` | `<OPPI_DATA_DIR>/diagnostics/telemetry/client-logs-YYYY-MM-DD.jsonl` | Redacted warning/error breadcrumbs and selected high-value info logs. |
| Server resource metrics | local JSONL writer | `<OPPI_DATA_DIR>/diagnostics/telemetry/server-metrics-YYYY-MM-DD.jsonl` | Server CPU, memory, event loop, sessions, and WebSocket counts. |
| Server ops metrics | local JSONL writer | `<OPPI_DATA_DIR>/diagnostics/telemetry/server-ops-metrics-YYYY-MM-DD.jsonl` | Server WebSocket, session, turn, gate, dictation, retry, and compaction metrics. |
| Server log | local JSONL/text log | `<OPPI_DATA_DIR>/server.log` | Structured server events and warnings. |

Retention defaults:

| Data | Default retention | Environment override |
|---|---:|---|
| MetricKit | 14 days | `OPPI_METRICKIT_RETENTION_DAYS` |
| Chat metrics | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Client logs | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Server resource metrics | 30 days | `OPPI_SERVER_METRICS_RETENTION_DAYS` |
| Server ops metrics | 30 days | `OPPI_SERVER_OPS_METRICS_RETENTION_DAYS` |

## Experience metrics that belong on the front page

The front page should focus on metrics that map directly to user experience. Low-level counters stay available for drill-down, but they should not define the product health story.

### App and session responsiveness

| Metric | Why it matters |
|---|---|
| `chat.app_launch_ms` | Time until the app presents useful content. |
| `chat.workspace_load_ms` | Time until the workspace screen is usable. |
| `chat.session_load_ms` | Time from selecting a session to chat content visible. |
| `chat.session_switch_ms` | Session row tap-to-content latency. |
| `chat.ttft_ms` | User-perceived time to first assistant response token. |
| `chat.fresh_content_lag_ms` | Delay between new stream content and visible timeline freshness. |

### Connection and queue reliability

| Metric or source | Why it matters |
|---|---|
| `chat.ws_wait_for_connected_ms` | Client wait before commands can use the focused session stream. |
| `server.ws_handshake_ms` | Server-side WebSocket upgrade latency. |
| `server.session_subscribe_ms` | Server session subscribe/catch-up path latency. |
| `chat.queue_sync_ms` | Time to refresh queued steer/follow-up state. |
| `chat.message_queue_ack_ms` | Time from queue command send to server acknowledgement. |
| `chat.message_queue_stale_drop` | User input was dropped because the client had stale session state. |
| `server.ws_ping_timeout` | Dead connection detection. |
| Client logs: `WebSocket`, `Network` | Reconnect storms, HTTP 1011s, POSIX disconnects, and endpoint changes. |

### Timeline rendering and scrolling

| Metric | Why it matters |
|---|---|
| `chat.timeline_apply_ms` | Snapshot/reducer apply time during streaming. |
| `chat.timeline_layout_ms` | UIKit layout cost during streaming. |
| `chat.cell_configure_ms` | Row rendering cost, especially large tool output rows. |
| `chat.markdown_streaming_ms` | Markdown streaming parse/build/apply cost. |
| `chat.jank_pct` | Percentage of render cycles over frame budget. |
| `chat.timeline_hitch` | Count of detected frame-budget hitches. |

### Dictation and voice input

| Metric | Why it matters |
|---|---|
| `chat.dictation_setup_ms` | Time from starting dictation to ready state. |
| `chat.dictation_first_result_ms` | Time until the user sees first transcript feedback. |
| `chat.dictation_finalize_ms` | Stop-to-final-result latency. |
| `chat.dictation_preview_final_delta` | How much final text changed from the preview. |
| `server.dictation_stt_ms` | Backend STT latency. |
| `server.dictation_stt_audio_ratio` | STT real-time factor. |
| `chat.dictation_error` and `server.dictation_error` | User-visible dictation failures. |

### Resource health and crash diagnostics

| Metric or source | Why it matters |
|---|---|
| `device.cpu_pct` | Client CPU usage during real interaction. |
| `device.memory_mb` | Client memory footprint. |
| `device.memory_available_mb` | Headroom before jetsam; low is bad. |
| `device.thermal_state` | Thermal pressure that can make the app feel slow. |
| `server.cpu_total` | Server CPU saturation. |
| `server.event_loop_lag_ms` | Server event-loop delay during sampler intervals. |
| `server.rss_mb` and `server.heap_mb` | Server memory pressure. |
| `server.sessions_total` and `server.ws_connections` | Local server concurrency pressure. |
| MetricKit diagnostics | Crashes, hangs, CPU exceptions, and disk-write exceptions. |
| Client logs | Breadcrumbs for what the user was doing before failure. |

## Informational metrics policy

Informational metrics are useful for debugging, but they must not drown out the experience story.

A metric belongs on the front page only when it has all of these:

1. A user-visible question it answers.
2. A unit and owner.
3. A bounded tag set.
4. A release threshold, trend, or explicit investigation use.
5. Enough context to debug, usually `sessionId`, `workspaceId`, and low-cardinality tags.

Keep informational metrics when they are low-volume or needed for drill-down. Aggregate, sample, demote, or remove them when they are high-volume and do not affect a release decision.

Server operational metrics can be aggregated before storage. For sum-aggregated counters, `value` is the event sum for the roughly one-minute flush bucket; dashboards should use `SUM(value)`, not row count, when showing throughput. For max-aggregated gauges such as fanout and ring utilization, `value` is the peak seen in the flush bucket.

Current handling guidance:

| Pattern | Action |
|---|---|
| Per-message counters such as `server.ws_message_sent` | Keep for drill-down, but sum-aggregate by path/type/status instead of showing raw sample volume. |
| Ephemeral UI counters such as `chat.tool_update_count` | Keep only if they explain a UX metric; otherwise sample or summarize by session. |
| Server HTTP timings such as `server.http_request_ms` | Promote only route groups that affect visible UX; fast successful health/stats/capability/navigation/telemetry-upload routes are threshold-gated. |
| Server drill-down gauges such as `server.broadcast_fanout` and `server.event_ring_utilization` | Max-aggregate by bounded tags; use peaks for diagnostics instead of raw sample counts. |
| Server resource snapshots such as active-session peak | Prefer the structured server resource sample over duplicating the same value into server-ops metrics. |
| Hot-path policy timings such as `server.gate_check_ms` | Emit slow samples only; keep decision counts as sum-aggregated counters. |
| Paired metrics such as coalescer events/bytes | Aggregate over a larger window and drop tiny partial drain windows; keep them as drill-down, not front-page rows. |
| Render drill-down metrics such as `chat.render_strategy_ms` | Keep signposts for every operation, but upload only non-trivial samples. |
| Routine command metrics such as successful `get_queue` command send/resolve/roundtrip | Keep errors and slow samples; rely on queue UX metrics for the normal success path. |
| Server token and cost counters such as `server.turn_input_tokens` and `server.turn_cost` | Sum-aggregate before storage; dashboards should use `SUM(value)`. |
| Client session-size snapshots such as `chat.session_input_tokens` | Emit only stable non-empty snapshots; dashboards should treat them as latest/max capacity diagnostics, not per-update events. |
| Rare error counters | Prefer a single error metric with a `reason` tag over many near-zero standalone metrics. |
| Stale or redundant metrics | Stop emitting them and keep import compatibility only when old dashboards need it. |

## How Oppi uses Pi observability

Pi persists sessions as JSONL and emits structured `AgentSessionEvent` values for lifecycle, streaming, tool execution, retry, compaction, and queue state. Oppi uses those primitives as the raw truth, then derives user-facing diagnostics:

- server turn duration and server-side time to first token
- token and cost snapshots
- tool-call counts and mutating-file stats
- retries, compactions, and compaction duration
- ask/permission round-trip timing
- session summaries and catch-up events for clients

Use Pi session files for forensic replay. Use Oppi metrics to answer whether the app felt good and where the interaction became slow, unreliable, or unsafe.

## Local dashboards and importer

The optional Grafana stack imports JSONL files into SQLite and serves prebuilt dashboards.

```bash
cd server
npm run telemetry:grafana:up
```

Importer notes:

- reads JSONL from `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`
- writes SQLite into a Docker-managed volume for Grafana; Grafana opens it read-write so SQLite WAL-mode read queries can create sidecar shared-memory files
- can also run manually with `npm run telemetry:import`
- normalizes append-only daily JSONL files incrementally
- flattens common server-op tags for split-stream panels

See `server/README.md` for the full dashboard runbook.

## Tag vocabulary

Use the same tag names across clients, server metrics, logs, and dashboards when possible.

| Tag | Use |
|---|---|
| `status` | Mechanical request outcome: `ok`, `error`, `cancelled`, or `timeout`. |
| `result` | Domain result, such as catch-up result: `applied`, `no_gap`, `ring_miss`, `fetch_failed`. |
| `reason` | Why an event happened, such as `capabilityRefreshFailed` or `idle_timeout`. |
| `transport` | User-selected or active transport path for metric samples: `lan`, `paired`, or `unknown`. |
| `streamRole` | WebSocket role in client logs, such as `focused_session` or another low-cardinality stream name. |
| `error_kind` | Coarse error class for metrics: `network`, `timeout`, `decode`, `cancelled`, `not_connected`, or `other`. |

Prefer logs over metrics for raw platform error details such as `NSURLErrorDomain`, HTTP status, or WebSocket close code. Use metrics for bounded counts, durations, and ratios.

## Adding or changing a metric

Before adding a metric, answer these questions in the code review:

1. What user experience question does this metric answer?
2. Is this a front-page metric, drill-down metric, or temporary investigation metric?
3. What is the unit?
4. What tags are allowed, and are they bounded?
5. Does the sample include session/workspace context when that is useful?
6. What is the removal or promotion trigger if this is temporary?

Implementation rules:

- Add chat/client metrics to `server/src/types/telemetry.ts` first.
- Mirror chat/client metric names in `clients/apple/Oppi/Core/Services/MetricKitModels.swift`.
- Add server operational metrics to `server/src/server-metric-registry.ts` first.
- Update tests when a metric contract changes.
- Prefer fewer, better-shaped metrics over broad logging-by-metric.
