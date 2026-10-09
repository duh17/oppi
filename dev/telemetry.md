# Telemetry and diagnostics

Oppi records diagnostics to answer one question: **does the app feel fast, reliable, and safe while someone supervises a Pi session from Apple clients?**

This page is the in-repo source of truth for available telemetry, its gates and storage, and the metrics that matter to user experience. It is not part of the public user docs.

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
npm run telemetry:review -- --http --days 1
npm run telemetry:review -- --models --days 7
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
# Dashboards: Release Preflight, Server Health, Model Routing
```

Release Preflight is the experience view: UX latency, connection readiness, client network, dictation, thread load beside workspace load and session switch, and collapsed command, quick-session, and share-publish drill-down. Server Health is resource and server-ops health: event-loop p99 trend and max gate, per-route HTTP latency and response bytes, and collapsed session, push, event-ring, MCP connect, schedule run, and dictation drill-down. Model Routing compares provider, model, and runtime workload.

## Privacy model

Oppi diagnostics are designed for self-hosted debugging.

- Public iOS release builds set `OPPI_TELEMETRY_MODE=public`.
- Public iOS release builds do not upload diagnostics unless the user enables **Settings → Privacy & Security → Send Diagnostics**.
- iOS builds do not link an external crash-reporting SDK; diagnostics upload only to the configured Oppi server.
- Internal/debug builds set `OPPI_TELEMETRY_MODE=internal` and upload diagnostics automatically to the configured Oppi server.
- The server also enforces `OPPI_TELEMETRY_MODE`: `public`, `release`, `prod`, `off`, and equivalent values reject telemetry uploads with HTTP 403.

Telemetry must not include:

- prompt text
- assistant output
- tool arguments
- command output content
- dictation transcript text
- relay URLs or relay hosts
- IP addresses
- tokens, tickets, node IDs, endpoint IDs, secrets, or credentials
- other raw URLs or local file paths

Allowed diagnostic data:

- low-cardinality IDs such as session ID, workspace ID, app instance ID, and boot ID
- low-cardinality tags such as `transport=lan`, `status=ok`, `error_kind=network`, or `tool=bash`
- numeric timings, counts, ratios, byte counts, and resource samples
- sanitized MetricKit summaries and crash, hang, CPU, disk, and app-launch diagnostics
- coarse screen, scene-phase, lifecycle-step, and main-thread stall context
- redacted client logs

## Upload channels

| Channel                 | Endpoint                       | Stored at                                                                   | Purpose                                                                                             |
| ----------------------- | ------------------------------ | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Chat metrics            | `POST /telemetry/chat-metrics` | `<OPPI_DATA_DIR>/diagnostics/telemetry/chat-metrics-YYYY-MM-DD.jsonl`       | Client UX, rendering, queueing, dictation, and device metrics.                                      |
| MetricKit               | `POST /telemetry/metrickit`    | `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`          | Apple crash, hang, CPU, disk, battery, and app-launch diagnostics with bounded correlation context. |
| Client logs             | `POST /telemetry/client-logs`  | `<OPPI_DATA_DIR>/diagnostics/telemetry/client-logs-YYYY-MM-DD.jsonl`        | Redacted warning/error events plus selected lifecycle, recovery, network, and memory info logs.     |
| Server resource metrics | local JSONL writer             | `<OPPI_DATA_DIR>/diagnostics/telemetry/server-metrics-YYYY-MM-DD.jsonl`     | Server CPU, memory, event loop, sessions, and WebSocket counts.                                     |
| Server ops metrics      | local JSONL writer             | `<OPPI_DATA_DIR>/diagnostics/telemetry/server-ops-metrics-YYYY-MM-DD.jsonl` | Server WebSocket, session, turn, extension UI, dictation, retry, and compaction metrics.            |
| Server log              | local JSONL/text log           | `<OPPI_DATA_DIR>/server.log`                                                | Structured server events and warnings.                                                              |

Retention defaults:

| Data                    | Default retention | Environment override                     |
| ----------------------- | ----------------: | ---------------------------------------- |
| MetricKit               |           14 days | `OPPI_METRICKIT_RETENTION_DAYS`          |
| Chat metrics            |           14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS`       |
| Client logs             |           14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS`       |
| Server resource metrics |           30 days | `OPPI_SERVER_METRICS_RETENTION_DAYS`     |
| Server ops metrics      |           30 days | `OPPI_SERVER_OPS_METRICS_RETENTION_DAYS` |

## Metric taxonomy

Use this split when reading dashboards or telemetry reviews:

| Category                    | Meaning                                                             | Examples                                                                                                                                                       | How to read it                                                                                                                                                                                                                                                                              |
| --------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UX responsiveness           | The user is waiting for the app, stream, or media to become usable. | `chat.ttft_ms`, `chat.session_load_ms`, `chat.ws_wait_for_connected_ms`, `chat.media_playback_start_ms`                                                        | High values are user-visible latency. These belong on the front page and can have SLOs.                                                                                                                                                                                                     |
| Reliability counters        | A user action, stream, or render path failed or recovered.          | `chat.message_queue_stale_drop`, `server.mcp_connect_ms`, `server.schedule_run_ms`, client logs                                                                | Split by `status` and `reason`. A connected MCP sample or completed schedule run is not a failure.                                                                                                                                                                                          |
| Agent workload and progress | The agent is actively doing work.                                   | `server.turn_duration_ms`, `server.turn_tool_calls`, `server.tool_duration_ms`, `server.tool_result`, `server.turn_input_tokens`, `chat.session_files_changed` | Long values are not automatically bad. Correlate with progress, tokens, tools, file changes, errors, and TTFT before calling it a stall. `npm run telemetry:review -- --models` compares exact provider/model and model+tool latency. Operational success is not accepted-task correctness. |
| Resource health             | Local client/server pressure that can make UX worse.                | `device.memory_mb`, `server.heap_mb`, `server.event_loop_lag_ms`                                                                                               | Diagnose capacity or leaks; do not confuse with agent productivity.                                                                                                                                                                                                                         |
| Drill-down internals        | Mechanical sub-steps used to explain a front-page metric.           | `chat.queue_sync_ms`, `server.session_subscribe_ms`, `server.http_response_bytes`                                                                              | Keep available, but do not let them define product health by themselves. Response bytes share the HTTP request gate.                                                                                                                                                                        |

`server.turn_duration_ms` is workload telemetry. It measures the full wall-clock duration of an agent turn. A long turn can mean the agent is handling a large task, running tools, editing files, waiting on tests, or processing a large context. Treat it as a problem only when it combines with missing progress signals, high first-token latency, stuck tool calls, errors, blocked asks, or disconnected clients.

Turn and tool ops metrics carry a bounded `runtime` tag: `oppi` (classic SDK), `durable` (live durable engine: `serverDurable` and no Pi session file), or `pi-tui` (terminal mirror). They also carry the exact session-configured `provider` and `model` route when the session already has a canonical `provider/modelId`. A bounded `thinking` tag records the session-configured reasoning level when it is one of Pi's known levels. Provider fallback or per-response reasoning changes can differ from those configured-route tags. Per-tool `server.tool_duration_ms` and `server.tool_result` pair concurrent calls by `toolCallId`. An end event without a matching start records a result without duration; starts without an end are discarded at turn end. These samples never include tool arguments, output, or file paths. Use `npm run telemetry:review -- --models` to compare observed TTFT, turn and tool latency, call frequency, token use, total observed cost/output divided by tool starts, and mechanical error rates. The cost/output ratios are route-level efficiency indicators across all observed turns, not costs attributable to individual tools. Historical samples without provider/model or runtime tags stay in an explicit untagged bucket. `npm run telemetry:review -- --models` includes the runtime breakdown. A `status=ok` tool result means the tool finished without a mechanical error; it does not mean the agent completed the accepted task correctly.

## Experience metrics that belong on the front page

The front page should focus on metrics that directly map to user experience. Keep low-level counters available for drill-down, but do not let them define the product health story.

### App and session responsiveness

| Metric                      | Why it matters                                                   |
| --------------------------- | ---------------------------------------------------------------- |
| `chat.app_launch_ms`        | Time until the app presents useful content.                      |
| `chat.workspace_load_ms`    | Time until the workspace screen is usable.                       |
| `chat.session_load_ms`      | Time from selecting a session to chat content visible.           |
| `chat.session_switch_ms`    | Session row tap-to-content latency.                              |
| `chat.thread_load_ms`       | Time from opening a thread until its snapshot is applied.        |
| `chat.ttft_ms`              | User-perceived time to first assistant response token.           |
| `chat.fresh_content_lag_ms` | Delay between new stream content and visible timeline freshness. |

### Connection and queue reliability

| Metric or source                                      | Why it matters                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `chat.ws_wait_for_connected_ms`                       | Client wait before commands can use the focused session stream.                                   |
| `server.ws_handshake_ms`                              | Server-side WebSocket upgrade latency.                                                            |
| `server.session_subscribe_ms`                         | Server session subscribe/catch-up path latency.                                                   |
| `chat.queue_sync_ms`                                  | Time to refresh queued steer/follow-up state.                                                     |
| `chat.message_queue_ack_ms`                           | Time from queue command send to server acknowledgement.                                           |
| `chat.message_queue_stale_drop`                       | User input was dropped because the client had stale session state.                                |
| `chat.app_event_stream_connect_ms`                    | Time until global app updates, attention cards, and session list events are live.                 |
| `chat.app_event_stream_reconnect`                     | Global app-event stream reconnect attempts and exhaustion.                                        |
| `chat.app_event_stream_decode_error`                  | Global app-event stream payload/schema failures.                                                  |
| `server.ws_ping_timeout`                              | Dead connection detection.                                                                        |
| Client logs: `WebSocket`, `AppEventStream`, `Network` | Reconnect storms, HTTP 1011s, POSIX disconnects, endpoint changes, and app-event stream failures. |

### Attention and media interactions

| Metric                         | Why it matters                                                                         |
| ------------------------------ | -------------------------------------------------------------------------------------- |
| `chat.ask_response_ms`         | How long the visible ask card blocked the agent before answer or ignore.               |
| `chat.media_playback_start_ms` | Time from media preview/player setup to playable video or audio.                       |
| `chat.media_playback_error`    | User-visible media preview/player failures by media kind and phase.                    |
| Client logs: `MediaPlayback`   | Playback/source failures with privacy-safe kind, source, phase, mode, and error class. |

### Timeline rendering and scrolling

| Metric                       | Why it matters                                         |
| ---------------------------- | ------------------------------------------------------ |
| `chat.timeline_apply_ms`     | Snapshot/reducer apply time during streaming.          |
| `chat.timeline_layout_ms`    | UIKit layout cost during streaming.                    |
| `chat.cell_configure_ms`     | Row rendering cost, especially large tool output rows. |
| `chat.markdown_streaming_ms` | Markdown streaming parse/build/apply cost.             |
| `chat.jank_pct`              | Percentage of render cycles over frame budget.         |
| `chat.timeline_hitch`        | Count of detected frame-budget hitches.                |

### Dictation and voice input

| Metric                                              | Why it matters                                      |
| --------------------------------------------------- | --------------------------------------------------- |
| `chat.dictation_setup_ms`                           | Time from starting dictation to ready state.        |
| `chat.dictation_first_result_ms`                    | Time until the user sees first transcript feedback. |
| `chat.dictation_finalize_ms`                        | Stop-to-final-result latency.                       |
| `chat.dictation_preview_final_delta`                | How much final text changed from the preview.       |
| `server.dictation_stt_ms`                           | Backend STT latency.                                |
| `server.dictation_stt_audio_ratio`                  | STT real-time factor.                               |
| `chat.dictation_error` and `server.dictation_error` | User-visible dictation failures.                    |

### Resource health and crash diagnostics

| Metric or source                                    | Why it matters                                                                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `device.cpu_pct`                                    | Client CPU usage during real interaction.                                                                                      |
| `device.memory_mb`                                  | Client memory footprint.                                                                                                       |
| `device.memory_available_mb`                        | Headroom before jetsam; low is bad.                                                                                            |
| `device.thermal_state`                              | Thermal pressure that can make the app feel slow.                                                                              |
| `server.cpu_total`                                  | Server CPU saturation.                                                                                                         |
| `server.event_loop_lag_ms`                          | Server event-loop delay p99 during sampler intervals. Derived by review from the resource sample, not an ops-registry emitter. |
| `server.rss_mb` and `server.heap_mb`                | Server memory pressure.                                                                                                        |
| `server.sessions_total` and `server.ws_connections` | Local server concurrency pressure.                                                                                             |
| MetricKit diagnostics                               | Crashes, hangs, CPU exceptions, disk-write exceptions, and app-launch diagnostics.                                             |
| Client logs                                         | Redacted diagnostic context for what happened before failure.                                                                  |

## Lifecycle and hang correlation

The Apple client persists a bounded diagnostic context locally so a later MetricKit payload can be tied to what the app was doing. The context can include session, workspace, and active-server IDs; a coarse screen label; scene phase; the latest lifecycle step; focused-stream state; and large timeline-payload counts and sizes. It does not include prompt, response, tool, URL, or file-path content.

A release-build watchdog probes the main thread once per second while the app is active. A probe that cannot run within 700 ms records a stall sequence, threshold, timestamp, and current memory footprint. Recovery records the measured duration. Repeated notices for the same stall are limited to one every two seconds. The watchdog remains available for ten seconds after the app enters the background so background-transition hangs can retain their final lifecycle step.

Scene transitions record ordered steps around restoration, background keep-alive, audio transport, and graceful connection close. Background steps, watchdog detections and recoveries, and MetricKit diagnostic notices force the client-log queue to flush in submission order.

MetricKit usually delivers crash and hang diagnostics after the affected process has ended. On the first diagnostic-context write in a new process, Oppi rotates the saved context into a previous-process slot. MetricKit diagnostic serialization uses that previous-process context, falling back to the current context only when no previous snapshot exists.

All remote upload rules still apply: public builds upload this context only when **Send Diagnostics to Server** is enabled, and the server stores it only in the telemetry files above. Use `telemetry:client-logs` to review lifecycle and watchdog events. The corresponding MetricKit JSONL record keeps the bounded context in its summary and raw `oppiDiagnosticContext` object.

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

| Pattern                                                                                        | Action                                                                                                                                                                              |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-message counters such as `server.ws_message_sent`                                          | Keep for drill-down, but sum-aggregate by path/type/status instead of showing raw sample volume.                                                                                    |
| Ephemeral UI counters such as `chat.tool_update_count`                                         | Keep only if they explain a UX metric; otherwise sample or summarize by session.                                                                                                    |
| Server HTTP timings such as `server.http_request_ms` and `server.http_response_bytes`          | Promote only route groups that affect visible UX; both use one threshold gate. Fast successful health/stats/capability/navigation/session-poll/telemetry-upload routes are omitted. |
| Server drill-down gauges such as `server.broadcast_fanout` and `server.event_ring_utilization` | Max-aggregate by bounded tags; use peaks for diagnostics instead of raw sample counts.                                                                                              |
| Server resource snapshots such as active-session peak                                          | Prefer the structured server resource sample over duplicating the same value into server-ops metrics.                                                                               |
| Paired metrics such as coalescer events/bytes                                                  | Aggregate over a larger window and drop tiny partial drain windows; keep them as drill-down, not front-page rows.                                                                   |
| Render drill-down metrics such as `chat.render_strategy_ms`                                    | Keep signposts for every operation, but upload only non-trivial samples.                                                                                                            |
| Routine command metrics such as successful `get_queue` command send/resolve/roundtrip          | Keep errors, cancellations, and slow samples; rely on queue UX metrics for the normal success path. `outcome=error` is a user-visible failure, not a cancelled or superseded refresh. |
| Server token and cost counters such as `server.turn_input_tokens` and `server.turn_cost`       | Sum-aggregate before storage; dashboards should use `SUM(value)`.                                                                                                                   |
| Client session-size snapshots such as `chat.session_input_tokens`                              | Emit only stable non-empty snapshots; dashboards should treat them as latest/max capacity diagnostics, not per-update events.                                                       |
| Rare error counters                                                                            | Prefer a single error metric with a `reason` tag over many near-zero standalone metrics.                                                                                            |
| Stale or redundant metrics                                                                     | Stop emitting them and keep import compatibility only for archived dashboards.                                                                                                      |

## How Oppi uses Pi observability

Pi persists sessions as JSONL and emits structured `AgentSessionEvent` values for lifecycle, streaming, tool execution, retry, compaction, and queue state. Oppi treats those primitives as the raw truth, then derives user-facing diagnostics:

- server turn duration and server-side time to first token, tagged by the exact session-configured provider/model route when known
- token and cost snapshots
- per-tool duration and mechanical result counts, plus turn tool-call counts and mutating-file stats
- retries, compactions, and compaction duration
- ask and extension UI round-trip timing
- session summaries and catch-up events for clients

Use Pi session files for forensic replay. Use Oppi metrics to answer whether the app felt good and where the interaction became slow, unreliable, or unsafe.

## Local dashboards and importer

The optional Grafana stack imports JSONL files into SQLite and serves three dashboards: Release Preflight, Server Health, and Model Routing.

```bash
cd server
npm run telemetry:grafana:up
```

Query stored rows by how they were written:

- Sum-aggregated counters (`server.ws_message_sent`, `server.ws_message_received`, `server.ws_binary_received_bytes`, `server.turn_input_tokens`, `server.turn_output_tokens`, `server.turn_cost`): `value` is the flush-bucket sum. Use `SUM(value)`. Row count is buckets, not events.
- Max-aggregated gauges (`server.broadcast_fanout`, `server.event_ring_utilization`): `value` is the flush-bucket peak. Use `MAX(value)`.
- Raw samples, including `server.http_request_ms`, session-create timings, dictation timings, and chat metrics: `value` is one measurement. Use percentiles or `AVG`/`MAX` of `value`, and `COUNT(*)` for sample count. Do not treat that count as request volume when the emitter omits fast successful routine routes.

`telemetry:review -- --http` uses the same raw-sample rule for `server.http_request_ms` and `server.http_response_bytes`: latency p50/p90/p99, sample count, and `status_code >= 400` rate, plus response-byte p50/p90/max, by method and `path_pattern`. Percentiles are nearest-rank.

`chat.thread_load_ms` has no release SLO. `chat.workspace_load_ms` (TM99 1000ms) and `chat.session_switch_ms` (TM99 600ms) were gated from observed headroom. Retained chat JSONL through 2026-10-09 has no `chat.thread_load_ms` samples; those samples start only after the iOS app that emits the metric is installed, so there is no TM99 to set a threshold against.

Importer notes:

- reads JSONL from `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`
- writes SQLite into a Docker-managed volume for Grafana; Grafana opens it read-write so SQLite WAL-mode read queries can create sidecar shared-memory files
- can also run manually with `npm run telemetry:import`
- normalizes append-only daily JSONL files incrementally, and reimports a file when the importer parser version changes
- flattens common server-op tags for split-stream panels. `provider`, `model`, and `runtime` stay in `tags_json`; dashboards read them with `json_extract`. The importer parser version stays 6.
- copies resource-sample `eventLoop` `p50`, `p95`, `p99`, and `max` into `server_metric_samples` (`event_loop_p50`, `event_loop_p95`, `event_loop_p99`, `event_loop_max`). Missing values stay NULL. Server Health plots p99 as the ungated trend and max as the stall gate.
- `telemetry:review` derives `server.event_loop_lag_ms` from the sampler p99 and `server.event_loop_max_ms` from the sampler max. The release gate uses only `server.event_loop_max_ms` (TM99 SLO 100ms). That threshold sits between the 2026-10-06 TM99 of 50ms and the 2026-10-07 TM99 of 111ms. The p99 series is a trend, not a second gate.

See `server/README.md` for the full dashboard runbook.

## Tag vocabulary

Use the same tag names across clients, server metrics, logs, and dashboards when possible.

| Tag            | Use                                                                                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `provider`     | Exact provider from the session-configured canonical `provider/modelId` route. Omitted when missing or malformed; a provider fallback can differ from this route.                                                                          |
| `model`        | Exact model id after the first `/` of the session-configured route, including nested ids such as `z.ai/glm-5`. Never a family alias.                                                                                                       |
| `thinking`     | Bounded session-configured Pi thinking level (`off` through `max`). Omitted when missing or unsafe; per-response reasoning can differ.                                                                                                     |
| `tool`         | Sanitized tool name (`[A-Za-z0-9._-]{1,64}`). Unsafe or missing names become `unknown`. Never arguments, output, or paths.                                                                                                                 |
| `status`       | Bounded mechanical outcome. Common values are `ok`, `error`, `cancelled`, and `timeout`; transport metrics also use `connected`, `failed`, `attempt`, `recovered`, `completed`, and `setup_failed`.                                        |
| `result`       | Domain result, such as catch-up result: `applied`, `no_gap`, `ring_miss`, `fetch_failed`. Compaction also uses `success`, `failed`, `aborted`, and `will_retry`.                                                                           |
| `transport`    | Active transport for metric samples: `http`, `lan`, `paired`, or `unknown`.                                                                                                                                                                |
| `path`         | Client samples: privacy-safe network path `direct` or `unknown`. Server WebSocket metrics reuse `path` for a bounded stream name (`bound_session_stream` or the app-event stream tag). Never an IP, endpoint ID, relay URL, or relay host. |
| `streamRole`   | WebSocket role in client logs, such as `focused_session` or another low-cardinality stream name.                                                                                                                                           |
| `error_kind`   | Coarse error class for metrics: `network`, `timeout`, `decode`, `cancelled`, `not_connected`, or `other`.                                                                                                                                  |
| `category`     | Bounded turn error class: `request_too_large`, `overloaded`, `rate_limit`, `auth`, `timeout`, `connection`, `json_parse`, `terminated`, `other`, or `unknown`.                                                                             |
| `runtime`      | Turn, tool, retry, and compaction ops metrics. `oppi` (classic SDK), `durable` (live durable engine; a `serverDurable` row with a Pi session file stays `oppi`), or `pi-tui` (terminal mirror).                                            |
| `kind`         | Schedule run kind: `due` or `manual`.                                                                                                                                                                                                      |
| `method`       | HTTP method on `server.http_request_ms` and `server.http_response_bytes`.                                                                                                                                                                  |
| `path_pattern` | Normalized HTTP route pattern. Not a file path. Requests that miss the route registry record `unregistered`, never the raw pathname.                                                                                                       |
| `status_code`  | HTTP status as a decimal string.                                                                                                                                                                                                           |
| `outcome`      | Subscribe result: `success` or `error`. Command send/roundtrip reuses it as `ok`, `cancelled`, or `error`. `error` is a user-visible failure; cancellation and supersession are `cancelled`, not `error`. Not renamed to `status`; already emitted. |
| `reason`       | Why an event happened, such as `capabilityRefreshFailed`, `idle_timeout`, `auth`, `connect`, `config`, `lease_lost`, `not_found`, `launch_in_progress`, or `other`.                                                                        |

Server ops samples also emit bounded tags that stay as stored: `attempt`, `success`, `push_type`, `ring`, `type`, `level`, `code`, `cancelled`, `questionCount`, `tokens`, `language`, `phase`, `audio_seconds`, `fatal`, and `sessionId`. Do not rename them; dashboards read the stored names. `success` is the push result (`true` or `false`), not `status`.

`telemetry:review` derives `server.cpu_total`, `server.rss_mb`, `server.heap_mb`, `server.sessions_total`, `server.ws_connections`, and `server.event_loop_lag_ms` from resource-sample fields (`cpu.total`, `memory.rss`, `memory.heapUsed`, `sessions.total`, `wsConnections`, `eventLoop.p99`). Those names are not in the ops registry and have no second emitter. `server.event_loop_lag_ms` is the interval p99.

Retired ops names are not emitted. They stay in the registry so archived dashboard imports still recognize them: `server.session_active_peak` (use `sessions.peak` on the resource sample), `server.dictation_retranscribe_ms`, `server.dictation_retranscribe_count`, and `server.dictation_retranscribe_skip`.

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
