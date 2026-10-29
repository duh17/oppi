# Telemetry and diagnostics

Oppi records diagnostics to answer one question: **does the app feel fast, reliable, and safe while someone supervises a Pi session from Apple clients?**

This page explains the telemetry, its gates and storage, and the events that matter to user experience. It is not part of the public user docs. Every event itself (name, fields and units, tags, emit policy, storage, group, SLO) is declared once in the telemetry catalog, `server/src/telemetry/catalog.ts`; see [Telemetry catalog](#telemetry-catalog).

## Scope

This page covers:

- Apple client diagnostics: MetricKit payloads, app events (UX, rendering, dictation, device), and redacted client logs.
- Server diagnostics: server events (operations and resource samples) and review commands.
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

Release Preflight is the experience view: UX latency, connection readiness, client network, dictation with each setup phase, voice playback, rendering cost against the 120 Hz budget, thread load beside workspace load and session switch, device CPU and memory by screen and app state with memory warnings and main-thread stalls, and collapsed command, quick-session, and share-publish drill-down. Server Health is resource and server-ops health: event-loop p99 trend and max gate, per-route HTTP latency and response bytes, and collapsed session, push, event-ring, MCP connect, schedule run, and dictation drill-down. Model Routing compares provider, model, and runtime workload.

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

| Channel       | Endpoint                      | Stored at                                                              | Purpose                                                                                                      |
| ------------- | ----------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| App events    | `POST /telemetry/events`      | `<OPPI_DATA_DIR>/diagnostics/telemetry/app-events-YYYY-MM-DD.jsonl`    | Client UX, rendering, connection, queueing, dictation, media, and device events.                             |
| MetricKit     | `POST /telemetry/metrickit`   | `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`     | Apple crash, hang, CPU, disk, battery, and app-launch diagnostics with bounded correlation context.          |
| Client logs   | `POST /telemetry/client-logs` | `<OPPI_DATA_DIR>/diagnostics/telemetry/client-logs-YYYY-MM-DD.jsonl`   | Redacted warning/error events plus selected lifecycle, recovery, network, memory, and navigation info logs.  |
| Server events | local writer                  | `<OPPI_DATA_DIR>/diagnostics/telemetry/server-events-YYYY-MM-DD.jsonl` | Server WebSocket, session, turn, tool, HTTP, push, MCP, schedule, and dictation events, and resource samples. |
| Server log    | local JSONL/text log          | `<OPPI_DATA_DIR>/server.log`                                           | Structured server events and warnings.                                                                       |

All three uploads carry the same `client` envelope: `{ kind: "ios" | "mac", appVersion?, buildNumber?, gitCommit?, osVersion?, deviceModel?, appInstanceId?, bootId? }`. `deviceModel` is the hardware identifier (`iPhone17,1`). An upload without a valid `client.kind` is refused with HTTP 400. MetricKit and client-log files keep their pre-envelope stored shape (client fields at the top level of each line).

Daily files are named by the server's UTC write date; readers filter by each record's `ts`.

Retention defaults:

| Data          | Default retention | Environment override                 |
| ------------- | ----------------: | ------------------------------------ |
| MetricKit     |           14 days | `OPPI_METRICKIT_RETENTION_DAYS`      |
| App events    |           14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS`   |
| Client logs   |           14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS`   |
| Server events |           30 days | `OPPI_SERVER_METRICS_RETENTION_DAYS` |

Daily byte caps (unset means no cap): `OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES` for each uploaded file, `OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES` for server events. The server cap counts every event except `server.resources` (about 2 MB a day): the writer tracks the cap-counted bytes of a day's file itself, so ops events cannot starve the Server Metrics page and resource samples cannot use up the ops budget. Pre-catalog files (`chat-metrics-*`, `server-ops-metrics-*`, `server-metrics-*`) are no longer written or read; the retention pass prunes them on their successor's retention so they age out.

## Server resource sampling and the Server Metrics page

`ServerResourceSampler` runs only while server config `serverMetrics.enabled` is true. It is opt-in (default false): off runs no timer, no event-loop histogram, no host reads, and writes no samples, so Server Health's resource panels and the `server.resources.event_loop_max_ms` release-gate input are empty until an operator turns it on. On, one sample costs about 1 ms (0.7 ms Node CPU on mac-studio including the `vm_stat` spawn wait, 0.4 ms in a Docker container). The process latches the switch at startup; a later config reload does not change it. The app's Server Settings toggle (`PUT /server/metrics/settings`) persists the switch and starts or stops sampling live; `oppi config set serverMetrics.enabled` needs a restart.

Each sample is one `server.resources` event, written at once (not buffered) to `server-events-*.jsonl`: process CPU (`cpu_total_pct`, share of one core, can exceed 100), memory in MB, session counts and the interval peak, WebSocket connections, event-loop delay p50/p95/p99/max for the interval, and `event_ring_peak_ratio` (the fullest session event ring, absent when no session holds one).

Each sample adds a `host` block (`host-resource-probe.ts`) in MB and percent: `scope` (`host` or `container`), `cpu` (busy share of `cpuCores`, 0–100), `cpuCores`, `load1` (hosts only), `memUsed`/`memTotal`, `diskUsed`/`diskTotal`. A host reads macOS memory from `vm_stat` (anonymous − purgeable + wired + compressed pages, Activity Monitor's Memory Used) and Linux memory as `MemTotal − MemAvailable`; CPU comes from `os.cpus()` times. A Linux process is a container when `/.dockerenv`, `/run/.containerenv`, `$container`, or `$KUBERNETES_SERVICE_HOST` exists; it then reads its cgroup (v2, else v1) like `docker stats`: memory is usage minus inactive file cache against `memory.max` (machine memory when unlimited), CPU is usage against the `cpu.max` quota (else `availableParallelism()`). A container whose cgroup cannot be read omits CPU and memory rather than reporting the machine. Disk is `statfs` on the data directory, used = total − available to the user. A failed read is omitted, never estimated. Process `cpu.total` stays a share of one core and can exceed 100.

In the event the host block becomes `host_cpu_pct`, `host_cpu_cores`, `host_cpu_limited`, `host_load1`, `host_mem_used_mb`, `host_mem_total_mb`, `host_mem_limited`, `host_disk_used_mb`, and `host_disk_total_mb`; an omitted reading is an absent field.

`GET /server/metrics?range=1h|24h|7d|30d` returns the latest sample and columnar avg/max series bucketed from the `server.resources` events in the daily server event files (`server-metrics-history.ts`): 1-minute, 5-minute, 30-minute, and 2-hour buckets. The response shape is the pre-catalog one. There are no derived files. A sample line is ~680 B (~2 MB/day at one sample per 30 s); reading 30 days with three other server events per sample takes ~280 ms on mac-studio, one day file at a time, skipping other events before parsing. The app refreshes 1h and 24h every 30 s and the longer ranges on pull.

## Telemetry catalog

`server/src/telemetry/catalog.ts` declares every event once. It is pure data plus types. Everything else derives from it or is checked against it:

| Consumer | How it uses the catalog |
| --- | --- |
| `POST /telemetry/events` (`routes/telemetry.ts`) | Validates each uploaded event's name, origin, fields and units, tag keys and values, and emit policy (`telemetry/validate.ts`); drops failing events and returns counts by reason. |
| Server emitters | `ServerTelemetry.record(name, fields, tags, ids?)` takes its types from the catalog, so an unknown event, field, tag, or enum value does not compile. Runtime validation repeats the check. |
| Server collector (`telemetry/server-telemetry.ts`) | Folds events whose `storage.aggregate` is set into one record per tag set, session, and workspace per 60 s flush window (sum or max per field). |
| iOS | `server/scripts/generate-telemetry-catalog.ts` writes `clients/apple/Oppi/Core/Telemetry/TelemetryCatalog.generated.swift`: one struct per `app.*` event with typed fields and tag enums, the emit policy, bucketing helpers, `name`-tag sanitizing, and the upload wire types. Never edit it by hand. |
| `npm run telemetry:review` | Reads groups, units, and SLOs; each event field is one series named `<event>.<field>`. |
| Grafana dashboards, alert rules, importer | The importer stores each v2 record as one `events` row. Dashboard and alert SQL names catalog events, fields, tags, and tag values; `check-telemetry.ts` fails on any that the catalog does not have. See [Local dashboards and importer](#local-dashboards-and-importer). |
| `npm run check` | `server/scripts/check-telemetry.ts` enforces the catalog invariants below, fails while the generated Swift or the generated event tables of this page are stale, and checks the dashboards, alert rules, importer, and review script against the catalog. |

### Naming and units

- Event names are `<origin>.<snake_case>`: `app.*` from the Apple client (the envelope's `client.kind` says iOS or Mac), `server.*` from the server.
- One logical event is one record. Values measured together are fields of one event (`server.http_request {duration_ms, response_bytes}`), not sibling samples.
- Field units: `ms`, `count`, `bytes`, `mb`, `pct` (0–100), `ratio` (0–1), `usd_micros`, `bool` (0 or 1). Field names end with the unit suffix (`_ms`, `_bytes`, `_mb`, `_pct`, `_ratio`, `_usd_micros`); `count` and `bool` fields have none. A field may be optional (a phase that did not run); an absent field is never written as 0.
- Numbers are never tags: counts and sizes are fields. IDs are never tags: `sessionId` and `workspaceId` are record fields.
- `emit` rules drop an event whose field is outside `[min, max)`, optionally only when its tags match. The generated Swift applies them before recording, as comparisons on each struct's own typed members (`passesEmitPolicy`), so a dropped event costs no dictionary, sanitizing, or string building; ingest applies them again.
- `slo` sets a TM99 threshold on one field, optionally only over events whose tags match (`where`), for example `app.trace_fetch.duration_ms` over `status=ok`. Rendering SLOs use the 120 Hz frame budget (8.3 ms).
- Removed events are deleted from the catalog, not retired.

### Tag vocabulary

Each tag key has exactly one meaning and one kind, declared in the catalog's `TAGS` table with its description:

- `enum`: a closed value list; an event may narrow it to a subset (the generated Swift gets a nested enum for that event).
- `bucket`: named size classes with shared edges (`output_size`, `input_size`: `under_1kb` … `over_200kb`); the generated Swift buckets the measured value.
- `name`: an open but bounded identifier (tool, model, provider, command, screen, route pattern, …) of 1 to 128 ASCII letters, digits, and `._/:@-`; anything else is stored as `unknown`. Values shaped like a location are stored as `unknown` too. The rules are data in the catalog (`NAME_LOCATION_RULES`: a URL scheme, `~` or a leading `/` (only the `path_pattern` route template may start with `/`), `localhost`, a private host suffix such as `.local` or `.ts.net`, IPv4, IPv6, `host.tld:port`, `user@host.tld`), so the server (`looksLikeLocation`) and the generated Swift (`TelemetryName`) apply exactly the same ones, and `protocol/telemetry-name-tags.json` is the one accept/reject list both test suites read. This is defence in depth, not a guarantee: a bare or public hostname (`stt-box`, `example.com`) or a relative path looks like any identifier, so **every source of a `name` tag must stay bounded**: a constant, an enum-like value, or a value the app or server already chose from a closed set. Today's sources are server-side message types, tool names, the configured provider/model route, registered route templates, HTTP methods and status codes, close codes, and STT provider names and model ids (the streaming STT provider reports the constant `streaming`, never its endpoint); and app-side command names, screen and stream-state labels, voice triggers and locales, render modes, content and result types, audio session and port types, playback sources and modes, export formats, and the quick-session workspace-selection label. A new `name` tag must not be fed a configured endpoint, a URL, or a path.

Shared meanings:

| Key | Meaning |
| --- | --- |
| `status` | Mechanical outcome of the measured operation: `ok`, `error`, `cancelled`, `timeout`. Success is always `ok`. |
| `result` | Event-specific domain outcome (catch-up taxonomy, push delivery, ask answered/empty/ignored, WebSocket wait, compaction `will_retry`, …), narrowed per event. |
| `reason` | Why the event happened (freshness source, reconnect cause, session end, schedule failure, …), narrowed per event. |
| `error_kind` | One coarse error vocabulary for every event, narrowed per event. Never a platform type name, error text, or code. |
| `phase` | Step of the operation in which the event happened, narrowed per event. |
| `stream` | Server WebSocket stream: `session`, `dictation`, `app_events`. |
| `transport` | Client connection transport: `paired`, `lan`, `unix`, or `local` (on-device, no server). |
| `provider`, `model`, `thinking`, `runtime` | The session-configured LLM route and runtime on server workload events. |

Keys that used to carry two meanings are split, and `check-telemetry.ts` refuses the old keys: server WebSocket `path` → `stream`; device `stream` → `stream_state`; `level` → `stream` (it always matched the stream); AVAudioSession `mode`/`category` → `audio_mode`/`audio_category`; STT `model`/`provider_id` → `stt_model`/`stt_provider`; turn error `category` → `error_kind`; load `path` → `load_path`; voice model `path` → `model_path`; `source` → `trigger`, `playback_source`, `load_source`, or `origin_surface`; command `outcome`, subscribe `outcome`, and resolve-lag `success` → `status`; network `failReason` → `error_kind`; push `event` → `notification`; schedule `kind` → `run_kind`; media `kind` → `media_kind`; message `type` → `message_type`; close `code` → `close_code`. The raw server `host` is never a tag.

### Wire format and storage

An events upload is `{ generatedAt, client, events: [{ ts, name, fields, tags?, sessionId?, workspaceId? }] }`, at most 500 events; extra events are dropped as `over_batch_limit`. The response is `{ ok: true, accepted, dropped: { <reason>: count } }`; drop reasons are `malformed`, `invalid_timestamp`, `over_batch_limit`, `unknown_event`, `wrong_origin`, `missing_field`, `unknown_field`, `invalid_field_value`, `missing_tag`, `unknown_tag`, `invalid_tag_value`, and `emit_policy`. A dropped event cannot succeed on retry. `protocol/telemetry-events-upload.json` is a golden upload encoded by the generated Swift; the server ingest test requires every event in it to be accepted.

Each stored event, from either origin, is one JSONL line:

```json
{ "v": 2, "ts": 1793000000000, "origin": "app", "name": "app.session_load",
  "fields": { "duration_ms": 412, "items": 87 }, "tags": { "load_path": "cache_hit" },
  "sessionId": "…", "workspaceId": "…", "client": { "kind": "ios", "buildNumber": "412", … } }
```

App events carry `client`; server events do not. An aggregated server record carries the window's sum or max in `fields` and the last event's `ts`; its count of events is not stored, so a catalog event that needs one declares a count field (`server.ws_message_sent.messages`).

### Apple client recording

The iOS app records one way: `Telemetry.record(AppTimelineApply(durationMs: 6, items: 40, changed: 2), sessionId:, workspaceId:)` (`clients/apple/Oppi/Core/Telemetry/Telemetry.swift`). Call sites pass a generated event struct; none passes a unit, builds a `[String: String]`, or caps tags. `record`:

1. applies the catalog `emit` rules first, before it builds any dictionary, so a call site does not repeat a duration floor (the catalog is the only place a threshold lives);
2. drops an event with a non-finite field, because one NaN would fail JSON encoding for the whole upload batch;
3. hands the event to `TelemetryEventUploader`, which keeps up to 1000 events, uploads batches of 50 to `POST /telemetry/events` when a batch fills or 10 s after the first buffered event, and keeps a batch when the upload fails (no 2xx). A 2xx never requeues, even when its body cannot be read: the accepted events are stored. The server's per-reason drop counts are logged (`TelemetryUpload` category) and the dropped events are not resent. The server logs `telemetry_events.dropped` once per reason and client build, so a build that emits a stale name or tag shows up in `server.log`.

Ambient state comes from one provider, `TelemetryContext`: `screen`, `stream_state`, `agents`, and `voice`. Every event that carries any of them (`app.device_resources`, `app.memory_warning`, `app.foreground`, the main-thread stall events) reads it there, and an unknown value is `unknown`, never absent. `sessionId` and `workspaceId` are passed to `record` by the code that knows them.

`TelemetryErrorKind.classify` is the one mapping from a thrown error to the catalog `error_kind` vocabulary (network failures, HTTP statuses, decode, cancellation, and the app's own error types). Swift type names, error text, and numeric codes never become tag values. The shared runtime (`OppiCore`, which the Mac target also compiles) names its vocabulary with enums whose raw values are catalog values (`ChatSessionRuntimeTelemetry.FreshnessReason`, `LoadPath`, `ReducerSource`, `CatchUpResult`); the iOS adapter maps them to generated types, and a test iterates every case so one without a catalog counterpart fails.

The client-log and MetricKit uploads carry the same `client` envelope as events (`TelemetryClientIdentity`; the simulator reports the device it emulates). A log line that used to carry numbers (memory warning, foreground footprint, main-thread stall, Live Voice call playback, diff reader session, HTTPS candidate) is now an event; the log line keeps only its message. `protocol/telemetry-events-upload.json` is also encoded by `TelemetryEventsUploadContractTests`, which fails on any byte difference.

### Event reference

The tables between the markers are generated from the catalog; `npm run check` fails while they are stale. Regenerate with `bun server/scripts/generate-telemetry-docs.ts`.

<!-- telemetry-catalog:begin (generated by server/scripts/generate-telemetry-docs.ts; do not edit) -->

Generated from `server/src/telemetry/catalog.ts`. A `*` marks a required tag; a field without "(optional)" is always present.

#### UX Responsiveness

User-visible wait time. Do not put full agent work duration in this group.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.ttft` | How long did the user wait for the first assistant token of a turn? | `duration_ms` ms | `provider`<br>`model` | SLO `duration_ms` TM99 ≤ 20000 |
| `app.catchup` | How long did catch-up take when (re)subscribing, and how did it resolve? | `duration_ms` ms | `result`*: `missing_epoch_baseline`, `missing_epoch`, `seq_regression`, `epoch_baseline`, `epoch_changed`, `no_gap`, `fetch_failed`, `not_live`, `epoch_mismatch`, `ring_miss`, `applied` | SLO `duration_ms` TM99 ≤ 500 |
| `app.cache_load` | How long did loading the cached timeline take? | `duration_ms` ms<br>`hit` bool<br>`events` count | none | SLO `duration_ms` TM99 ≤ 200 |
| `app.reducer_load` | How long did rebuilding the timeline reducer take? | `duration_ms` ms<br>`events` count<br>`items` count | `load_source`* | SLO `duration_ms` TM99 ≤ 200 |
| `app.session_load` | How long from selecting a session until its content was visible? | `duration_ms` ms<br>`items` count | `load_path`*: `cache_hit`, `cache_miss`, `full_reload`, `first_message_fallback`, `conversation_stream` | SLO `duration_ms` TM99 ≤ 600 |
| `app.fresh_content_lag` | How long until the timeline showed fresh content after connecting? | `duration_ms` ms<br>`cached` bool | `reason`*: `cache_hit`, `conversation_stream`, `reconnect_conversation_stream`, `reconnect_no_gap`, `reconnect_applied`, `reconnect_full_reload_scheduled`, `stream_seq`, `history_empty`, `history_applied_empty`, `history_deferred_to_live`, `history_unchanged`, `history_applied`, `history_replayed`, `history_first_message_fallback`<br>`transport`: `paired`, `lan`, `unix` | SLO `duration_ms` TM99 ≤ 1000 |
| `app.session_switch` | How long from tapping a session row until chat content was visible? | `duration_ms` ms<br>`cached` bool | none | emit `duration_ms` < 60000<br>SLO `duration_ms` TM99 ≤ 600 |
| `app.trace_fetch` | How long did fetching and decoding a trace page take? | `duration_ms` ms<br>`trace_events` count (optional) | `status`*: `ok`, `error`<br>`error_kind` | SLO `duration_ms` TM99 ≤ 1500 when status=ok |
| `app.thread_load` | How long from opening a thread until its snapshot was applied or failed? | `duration_ms` ms | `phase`*: `initial`, `refresh`<br>`status`*: `ok`, `error`<br>`error_kind` | none |
| `app.workspace_load` | How long until the workspace screen was usable? | `duration_ms` ms | `load_path`*: `open`, `return_from_chat` | emit `duration_ms` < 60000<br>SLO `duration_ms` TM99 ≤ 1000 |

#### Connection Reliability

Command/session readiness and stream health. These are user-blocking when they fail or tail out.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.ws_wait` | How long did the client wait for the focused session stream to connect? | `duration_ms` ms<br>`socks_generation` count | `route`<br>`host_kind`<br>`path_type`<br>`transport`: `paired`, `lan`, `unix`<br>`connection_state`*<br>`result`*: `already_connected`, `connected`, `timeout` | SLO `duration_ms` TM99 ≤ 1000 |
| `app.network_handshake` | How long did an HTTPS candidate handshake take on each route? | `duration_ms` ms<br>`socks_generation` count | `route`<br>`host_kind`<br>`path_type`<br>`transport`: `paired`, `lan`, `unix`<br>`status`*: `ok`, `error`<br>`error_kind` | none |
| `app.ws_ping` | What is the client WebSocket ping round-trip time on each route? | `rtt_ms` ms<br>`socks_generation` count | `route`<br>`host_kind`<br>`path_type`<br>`transport`: `paired`, `lan`, `unix` | emit `rtt_ms` ≥ 0 |
| `app.command` | How long did a session command take to send and to resolve? Fire-and-forget commands have no round trip. | `send_ms` ms<br>`roundtrip_ms` ms (optional) | `command`*<br>`transport`*: `paired`, `lan`, `unix`<br>`status`*: `ok`, `cancelled`, `error`<br>`error_kind` | emit `roundtrip_ms` ≥ 500 when command=get_queue, status=ok |
| `app.command_resolve_lag` | How long from a command_result frame arriving to its waiter resolving? | `lag_ms` ms | `command`*<br>`transport`*: `paired`, `lan`, `unix`<br>`status`*: `ok`, `error` | emit `lag_ms` ≥ 50 when command=get_queue, status=ok |
| `app.queue_sync` | How long did refreshing the queued steer/follow-up snapshot take? | `duration_ms` ms | `transport`*: `paired`, `lan`, `unix`<br>`phase`*: `initial`, `deferred`<br>`status`*: `ok`, `cancelled`, `error`<br>`error_kind` | SLO `duration_ms` TM99 ≤ 500 when status=ok |
| `app.message_queue_ack` | How long from a busy send to server acknowledgement? A turn that already ended prompts it normally. | `duration_ms` ms | `intent`*<br>`transport`*: `paired`, `lan`, `unix`<br>`status`*: `ok`, `error`<br>`error_kind` | SLO `duration_ms` TM99 ≤ 300 when status=ok |
| `app.message_queue_stale_drop` | Did the client drop a queue update because its queue state was stale? | `incoming_version` count<br>`current_version` count | `queue_event`* | none |
| `app.message_queue_start_miss` | Did a queue item start that the client never saw queued? | `queue_version` count | `intent`* | none |
| `app.app_event_stream_connect` | How long until global app updates, attention cards, and list events were live? | `duration_ms` ms<br>`attempt` count<br>`snapshot_required` bool | none | SLO `duration_ms` TM99 ≤ 1000 |
| `app.app_event_stream_reconnect` | Why and how often did the global app-event stream schedule a reconnect? | `attempt` count<br>`socks_generation` count | `route`<br>`host_kind`<br>`path_type`<br>`transport`: `paired`, `lan`, `unix`<br>`reason`*: `receive_error`, `handshake_http`, `protocol_close`, `recoverable_receive`, `ping_watchdog`, `auth_current_token`, `auth_refresh`<br>`close_code` | none |
| `app.app_event_stream_decode_error` | Did a global app-event stream frame fail to decode? | none | `error_kind`*: `decode`, `network`, `other` | none |
| `server.ws_handshake` | How long did a WebSocket upgrade take on the server? | `duration_ms` ms | `stream`* | SLO `duration_ms` TM99 ≤ 100 |
| `server.session_subscribe` | How long did the server's session subscribe and catch-up path take? | `duration_ms` ms<br>`catchup_requested` bool<br>`catchup_complete` bool<br>`started_session` bool<br>`pending_ui_requests` count | `status`*: `ok`, `error` | SLO `duration_ms` TM99 ≤ 300 |

#### Rendering Smoothness

Frame-budget work on the 120 Hz budget (8.3 ms).

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.timeline_apply` | How long did a timeline snapshot apply take during streaming? | `duration_ms` ms<br>`items` count<br>`changed` count | none | emit `duration_ms` ≥ 4, < 5000<br>SLO `duration_ms` TM99 ≤ 8.3 |
| `app.timeline_layout` | How long did timeline layout take during streaming? | `duration_ms` ms<br>`items` count | none | emit `duration_ms` ≥ 2, < 5000<br>SLO `duration_ms` TM99 ≤ 8.3 |
| `app.cell_configure` | How long did configuring a timeline row take, especially large tool output? | `duration_ms` ms<br>`expanded` bool (optional) | `row_type`*<br>`tool`<br>`content_type`<br>`output_size` (bucket) | emit `duration_ms` ≥ 1, < 5000<br>SLO `duration_ms` TM99 ≤ 8.3 |
| `app.render_strategy` | How long did highlighting, ANSI parsing, or diff building take for a tool row? | `duration_ms` ms | `render_mode`*<br>`input_size`* (bucket)<br>`language` | emit `duration_ms` ≥ 1, < 5000 |
| `app.tool_row_measure` | How long did measuring a tool row's width or viewport take? | `duration_ms` ms | `measure`*<br>`input_size`* (bucket) | emit `duration_ms` ≥ 1 |
| `app.markdown_streaming` | How long did one streaming markdown parse, build, and apply cycle take? | `duration_ms` ms<br>`segments` count | `surface`* | emit `duration_ms` ≥ 1<br>SLO `duration_ms` TM99 ≤ 8.3 |
| `app.timeline_jank` | What share of timeline apply cycles in a session missed the frame budget? | `jank_pct` pct<br>`cycles` count<br>`hitches` count | none | emit `cycles` ≥ 1<br>SLO `jank_pct` TM99 ≤ 25 |
| `app.coalescer_window` | How much stream traffic did the delta coalescer flush per window of 200 flushes (or a non-trivial partial drain)? | `flushes` count<br>`events` count<br>`payload_bytes` bytes | none | none |
| `app.diff_reader_session` | How fast did a review diff open and how smoothly did it scroll? | `open_ms` ms<br>`lines` count<br>`chunks` count<br>`content_width_points` count<br>`scroll_frames` count<br>`hitches` count<br>`hitch_ratio` ratio<br>`worst_frame_ms` ms | none | none |

#### Attention and Media UX

Human-in-the-loop, sharing, and media playback. Ask response is user dwell time, not app latency.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.live_voice_leftover_call` | Did iOS keep CallKit calls listed after their Live Voice call was over? | `calls` count | `phase`*: `call_start`, `call_end`, `dictation_start` | emit `calls` ≥ 1 |
| `app.live_voice_call_playback` | How smoothly did Live Voice call audio play? | `chunks` count<br>`received_ms` ms<br>`max_gap_ms` ms<br>`underruns` count<br>`flushes` count<br>`min_prime_ms` ms<br>`final_prime_ms` ms<br>`max_lag_ms` ms<br>`audio_restarts` count<br>`echo_cancellation` bool | none | none |
| `app.voice_playback_start` | How long did voice replies and replayable voice media take to start playing? | `duration_ms` ms | `playback_source`*<br>`playback_mode` | none |
| `app.voice_playback_error` | Where did voice playback fail? | none | `playback_source`*<br>`phase`*: `start`, `load`, `stream`, `activate`, `chunk`<br>`error_kind`* | none |
| `app.media_playback_start` | How long from player setup to playable video or audio? | `duration_ms` ms | `media_kind`*<br>`playback_source`<br>`playback_mode` | SLO `duration_ms` TM99 ≤ 2000 |
| `app.media_playback_error` | Where did a media preview or player fail? | none | `media_kind`*<br>`playback_source`<br>`phase`*: `source`, `player_item`, `player_state`, `stall`<br>`error_kind`* | none |
| `app.ask_response` | How long did a visible ask card block the agent before answer or ignore? | `duration_ms` ms<br>`questions` count<br>`answered` count<br>`ignored` count<br>`multi_select_questions` count<br>`selected` count<br>`custom` bool<br>`allow_custom` bool | `result`*: `answered`, `empty`, `ignored`<br>`surface`<br>`response_encoding` | none |
| `app.share_export` | How long did rendering share-sheet content take? | `duration_ms` ms | `export_format`*<br>`content_type` | emit `duration_ms` ≥ 1 |
| `app.share_prepare` | How long did the shared-session redaction preflight take, and what did it find? | `duration_ms` ms<br>`findings` count (optional)<br>`replacements` count (optional)<br>`blocked` bool (optional)<br>`can_publish` bool (optional)<br>`redact_emails` bool<br>`redact_phones` bool<br>`redact_user_paths` bool<br>`redact_ip_addresses` bool<br>`redact_jwt_bearer` bool<br>`redact_names` bool<br>`redact_skills` bool | `status`*: `ok`, `error`<br>`error_kind` | none |
| `app.share_publish` | How long did publishing a shared session take? | `duration_ms` ms<br>`findings` count (optional)<br>`replacements` count (optional)<br>`redact_emails` bool<br>`redact_phones` bool<br>`redact_user_paths` bool<br>`redact_ip_addresses` bool<br>`redact_jwt_bearer` bool<br>`redact_names` bool<br>`redact_skills` bool | `status`*: `ok`, `error`<br>`error_kind` | none |
| `app.quick_session_create` | How long did creating a quick session take, and did it fail? An intent whose prompt was not delivered is status=error, error_kind=prompt_delivery. | `duration_ms` ms<br>`has_message` bool<br>`has_model` bool<br>`has_attachments` bool (optional)<br>`has_repo_refs` bool (optional)<br>`has_agent` bool (optional)<br>`incognito` bool (optional) | `origin_surface`*<br>`workspace_selection`<br>`worktree`<br>`session_engine`<br>`status`*: `ok`, `error`<br>`error_kind` | none |
| `server.ask_round_trip` | How long from a direct ask UI request to the user's answer? | `duration_ms` ms<br>`questions` count | `status`*: `ok`, `cancelled` | none |

#### Dictation UX

Client dictation and voice input as the user experiences it.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.dictation_prewarm` | How long did prewarming the voice pipeline take? | `duration_ms` ms | `voice_engine`*<br>`locale`<br>`trigger`<br>`status`*: `ok`, `cancelled`, `error`<br>`error_kind` | SLO `duration_ms` TM99 ≤ 100 when status=ok |
| `app.dictation_setup` | How long from starting dictation to recording, per setup phase? Failed or cancelled setups carry only total_ms. | `total_ms` ms<br>`model_ready_ms` ms (optional)<br>`transcriber_create_ms` ms (optional)<br>`analyzer_start_ms` ms (optional)<br>`audio_session_ms` ms (optional)<br>`audio_start_ms` ms (optional)<br>`engine_start_ms` ms (optional)<br>`first_audio_wait_ms` ms (optional)<br>`audio_sample_rate` count (optional) | `voice_engine`*<br>`locale`<br>`trigger`<br>`model_path`<br>`stt_provider`<br>`stt_provider_kind`<br>`stt_backend`<br>`stt_model`<br>`audio_category`<br>`audio_mode`<br>`audio_inputs`<br>`audio_outputs`<br>`audio_route`<br>`status`*: `ok`, `cancelled`, `error`<br>`error_kind` | SLO `total_ms` TM99 ≤ 350 when status=ok |
| `app.dictation_first_result` | How long until the user saw the first transcript feedback? | `duration_ms` ms | `voice_engine`*<br>`locale`<br>`trigger`<br>`model_path`<br>`stt_provider`<br>`stt_provider_kind`<br>`stt_backend`<br>`stt_model`<br>`audio_category`<br>`audio_mode`<br>`audio_inputs`<br>`audio_outputs`<br>`audio_route`<br>`result_type` | SLO `duration_ms` TM99 ≤ 6000 |
| `app.dictation_end` | How did a completed dictation take finish: finalize latency, length, and quality? | `finalize_ms` ms<br>`session_ms` ms<br>`audio_duration_ms` ms<br>`result_updates` count<br>`preview_final_delta_ratio` ratio<br>`input_level_peak_ratio` ratio | `voice_engine`*<br>`locale`<br>`trigger`<br>`model_path`<br>`stt_provider`<br>`stt_provider_kind`<br>`stt_backend`<br>`stt_model`<br>`audio_category`<br>`audio_mode`<br>`audio_inputs`<br>`audio_outputs`<br>`audio_route` | SLO `finalize_ms` TM99 ≤ 500<br>SLO `preview_final_delta_ratio` TM99 ≤ 0.15 |
| `app.dictation_capture_error` | Did audio capture fail while dictating? Setup failures are app.dictation_setup errors. | none | `voice_engine`*<br>`locale`<br>`trigger`<br>`model_path`<br>`stt_provider`<br>`stt_provider_kind`<br>`stt_backend`<br>`stt_model`<br>`audio_category`<br>`audio_mode`<br>`audio_inputs`<br>`audio_outputs`<br>`audio_route`<br>`error_kind`* | none |
| `app.dictation_cancel` | Did the user cancel a dictation take after recording started? | none | `voice_engine`*<br>`locale`<br>`trigger`<br>`model_path`<br>`stt_provider`<br>`stt_provider_kind`<br>`stt_backend`<br>`stt_model`<br>`audio_category`<br>`audio_mode`<br>`audio_inputs`<br>`audio_outputs`<br>`audio_route` | none |

#### Dictation Backend

Server speech-to-text and finalize work.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `server.dictation_first_audio` | How long from dictation_start to the first audio frame? | `duration_ms` ms | `stt_provider`*<br>`stt_backend`*<br>`stt_model`* | none |
| `server.dictation_first_result` | How long until the first visible streaming transcript, and how much audio had arrived? | `duration_ms` ms<br>`audio_ms` ms | `stt_provider`*<br>`stt_backend`*<br>`stt_model`* | none |
| `server.dictation_finalize` | How did a server dictation session finish: session length, final STT latency and real-time factor, and total finalize time? | `session_ms` ms<br>`audio_duration_ms` ms<br>`result_updates` count<br>`stt_ms` ms (optional)<br>`stt_audio_ratio` ratio (optional)<br>`finalize_ms` ms (optional) | `stt_provider`*<br>`stt_backend`*<br>`stt_model`*<br>`status`*: `ok`, `error`<br>`result`: `transcribed`, `no_audio`<br>`error_kind`: `stt` | SLO `stt_ms` TM99 ≤ 200<br>SLO `stt_audio_ratio` TM99 ≤ 0.1<br>SLO `finalize_ms` TM99 ≤ 250 |
| `server.dictation_stream_error` | Did the dictation stream refuse a connection or a message? | none | `reason`*: `dictation_unavailable`, `unsupported_message` | none |

#### Session List

Session list compute and SwiftUI body churn.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.session_list_compute` | How long did computing the session list view data take? | `duration_ms` ms<br>`active_sessions` count<br>`stopped_sessions` count | none | emit `duration_ms` ≥ 1<br>SLO `duration_ms` TM99 ≤ 10 |
| `app.session_list_row_compute` | How long did computing the visible session rows take? | `duration_ms` ms<br>`rows` count | none | emit `duration_ms` ≥ 1 |
| `app.session_list_body_rate` | How often did the session list body re-evaluate in a 5 s window (store churn)? | `evaluations` count | none | SLO `evaluations` TM99 ≤ 12 |

#### Device

Client CPU, memory, thermal pressure, and main-thread stalls.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.device_resources` | What did the app cost in CPU and memory, and how much headroom was left, on each screen and state? Sampled every 10 s. | `cpu_pct` pct (optional)<br>`memory_mb` mb (optional)<br>`memory_available_mb` mb<br>`thermal_state` count | `screen`<br>`stream_state`<br>`agents`<br>`voice` | SLO `cpu_pct` TM99 ≤ 20<br>SLO `memory_mb` TM99 ≤ 250<br>SLO `memory_available_mb` TM99 ≥ 100<br>SLO `thermal_state` TM99 ≤ 1 |
| `app.memory_warning` | How large was the app when iOS sent a memory warning, and what did it free? | `footprint_before_mb` mb (optional)<br>`footprint_after_mb` mb (optional)<br>`cache_entries` count<br>`cache_bytes` bytes | `screen` | none |
| `app.foreground` | How large was the app when it returned to the foreground? | `footprint_mb` mb (optional)<br>`reconnect` bool | `screen` | none |
| `app.main_thread_stall_detected` | Did the main thread miss the watchdog probe, and how large was the app? | `threshold_ms` ms<br>`footprint_mb` mb (optional)<br>`sequence` count | `screen` | none |
| `app.main_thread_stall_recovered` | How long did a detected main-thread stall last? | `duration_ms` ms<br>`sequence` count | `screen` | none |

#### Server

Resource pressure. event_loop_p99_ms is the ungated trend; the release gate uses event_loop_max_ms.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `server.resources` | How much CPU, memory, event-loop delay, and concurrency did the server and its host use? Sampled every 30 s while server metrics are on. | `cpu_total_pct` pct<br>`cpu_user_pct` pct<br>`cpu_system_pct` pct<br>`rss_mb` mb<br>`heap_used_mb` mb<br>`heap_total_mb` mb<br>`external_mb` mb<br>`sessions_busy` count<br>`sessions_ready` count<br>`sessions_starting` count<br>`sessions_total` count<br>`sessions_peak` count<br>`ws_connections` count<br>`event_loop_p50_ms` ms<br>`event_loop_p95_ms` ms<br>`event_loop_p99_ms` ms<br>`event_loop_max_ms` ms<br>`event_ring_peak_ratio` ratio (optional)<br>`host_cpu_pct` pct (optional)<br>`host_cpu_cores` count (optional)<br>`host_cpu_limited` bool (optional)<br>`host_load1` count (optional)<br>`host_mem_used_mb` mb (optional)<br>`host_mem_total_mb` mb (optional)<br>`host_mem_limited` bool (optional)<br>`host_disk_used_mb` mb (optional)<br>`host_disk_total_mb` mb (optional) | `host_scope` | SLO `cpu_total_pct` TM99 ≤ 10<br>SLO `rss_mb` TM99 ≤ 800<br>SLO `heap_used_mb` TM99 ≤ 200<br>SLO `ws_connections` TM99 ≤ 5<br>SLO `sessions_total` TM99 ≤ 8<br>SLO `event_loop_max_ms` TM99 ≤ 100 |

#### Agent Workload

Long values usually mean the agent was working. Call them bad only when correlated with no progress, high TTFT, tool hangs, errors, or missing UI updates. Operational success is not accepted-task correctness.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `app.session_usage` | How large has a session grown (messages, tokens, edits, context)? | `message_count` count<br>`input_tokens` count<br>`output_tokens` count<br>`mutating_tool_calls` count<br>`files_changed` count<br>`context_tokens` count<br>`context_window` count | `provider`<br>`model` | none |
| `server.turn` | How long did a full agent turn take, how many tools did it run, and did it end in an error? | `duration_ms` ms (optional)<br>`tool_calls` count (optional) | `runtime`*<br>`provider`<br>`model`<br>`thinking`<br>`status`*: `ok`, `error`<br>`error_kind`: `request_too_large`, `overloaded`, `rate_limit`, `auth`, `timeout`, `network`, `json_parse`, `terminated`, `other` | none |
| `server.turn_ttft` | How long from agent_start to the first text or thinking token on the server? | `duration_ms` ms | `runtime`*<br>`provider`<br>`model`<br>`thinking` | none |
| `server.turn_usage` | How many tokens and how much money did turns use, per route? | `input_tokens` count<br>`output_tokens` count<br>`cost_usd_micros` usd_micros | `runtime`*<br>`provider`<br>`model`<br>`thinking` | aggregate per 60 s: sum `input_tokens`, sum `output_tokens`, sum `cost_usd_micros` |
| `server.tool_call` | How long did a tool call take and did it fail mechanically? Unpaired ends have no duration. | `duration_ms` ms (optional) | `runtime`*<br>`provider`<br>`model`<br>`thinking`<br>`tool`*<br>`status`*: `ok`, `error` | none |
| `server.auto_retry` | How often did Pi auto-retry a turn? | `attempt` count | `runtime`*<br>`provider`<br>`model`<br>`thinking` | none |
| `server.compaction` | How long did auto-compaction take, and did it finish? | `duration_ms` ms (optional) | `runtime`*<br>`provider`<br>`model`<br>`thinking`<br>`status`*: `ok`, `error`, `cancelled`<br>`result`: `will_retry` | none |

#### Server Operations

HTTP routes, WebSocket plumbing, push, MCP, schedules, and session lifecycle drill-down.

| Event | Answers | Fields | Tags | Emit, storage, SLO |
| --- | --- | --- | --- | --- |
| `server.ws_first_message` | How long from WebSocket open to the first client message? | `duration_ms` ms | `stream`* | none |
| `server.ws_ping` | What is the server-initiated ping round-trip time? | `rtt_ms` ms | none | none |
| `server.ws_ping_timeout` | Did the server terminate a dead connection after missed pongs? | none | none | none |
| `server.ws_session` | How long did a WebSocket connection live, how busy was it, and how did it close? | `duration_ms` ms<br>`messages_sent` count<br>`messages_received` count | `stream`*<br>`close_code`* | none |
| `server.ws_message_sent` | How many frames did the server send, by stream and message type? | `messages` count | `stream`*<br>`message_type`* | aggregate per 60 s: sum `messages` |
| `server.ws_message_received` | How many frames and binary bytes did the server receive, by stream and type? | `messages` count<br>`binary_bytes` bytes | `stream`*<br>`message_type`* | aggregate per 60 s: sum `messages`, sum `binary_bytes` |
| `server.catchup` | Did the session event ring serve a catch-up, and how many events did it replay? | `events` count | `result`*: `replayed`, `miss` | none |
| `server.broadcast_fanout` | What was the peak subscriber count for durable broadcasts, by message type? | `subscribers` count | `message_type`* | aggregate per 60 s: max `subscribers` |
| `server.session_create` | How long did creating a session runtime take? | `duration_ms` ms | none | none |
| `server.sdk_session_setup` | How did classic SDK session creation split between SDK setup and extension bind? | `sdk_ms` ms<br>`bind_ms` ms | none | none |
| `server.session_end` | Why did sessions end? | none | `reason`*: `completed`, `stopped`, `error`, `idle_timeout`, `server_restart`, `store_failed`, `other` | none |
| `server.http_request` | How long did an HTTP request take and how many body bytes did it write? Fast successful routine routes are omitted. | `duration_ms` ms<br>`response_bytes` bytes (optional) | `method`*<br>`path_pattern`*<br>`status_code`* | none |
| `server.mcp_connect` | How long did the first MCP connect take on a durable session, and did it fail? | `duration_ms` ms | `status`*: `ok`, `error`<br>`error_kind`: `auth`, `connect`, `config` | none |
| `server.schedule_run` | How long did dispatching a schedule run take, and why did it fail? | `duration_ms` ms | `run_kind`*<br>`status`*: `ok`, `error`<br>`reason`: `lease_lost`, `not_found`, `launch_in_progress`, `other` | none |
| `server.push` | How did a push send resolve, and how long did seal-and-relay take? | `send_ms` ms (optional) | `notification`*<br>`result`*: `delivered`, `gone`, `rejected`, `unavailable`, `failed`, `throttled`, `no_activity` | none |

<!-- telemetry-catalog:end -->

## Event taxonomy

Use this split when reading dashboards or telemetry reviews. The catalog `group` of each event places it in a review group (UX Responsiveness, Connection Reliability, Rendering Smoothness, Attention and Media UX, Dictation UX, Dictation Backend, Session List, Device, Server, Agent Workload, Server Operations).

| Category | Meaning | Examples | How to read it |
| --- | --- | --- | --- |
| UX responsiveness | The user is waiting for the app, stream, or media to become usable. | `app.ttft`, `app.session_load`, `app.ws_wait`, `app.media_playback_start` | High values are user-visible latency. These belong on the front page and can have SLOs. |
| Reliability | A user action, stream, or render path failed or recovered. | `app.message_queue_stale_drop`, `server.mcp_connect`, `server.schedule_run`, client logs | Split by `status`, `reason`, and `error_kind`. |
| Agent workload and progress | The agent is actively doing work. | `server.turn`, `server.tool_call`, `server.turn_usage`, `app.session_usage` | Long values are not automatically bad. Correlate with progress, tokens, tools, file changes, errors, and TTFT before calling it a stall. `npm run telemetry:review -- --models` compares exact provider/model and model+tool latency. Operational success is not accepted-task correctness. |
| Resource health | Local client/server pressure that can make UX worse. | `app.device_resources`, `app.memory_warning`, `server.resources` | Diagnose capacity or leaks; do not confuse with agent productivity. |
| Drill-down internals | Mechanical sub-steps used to explain a front-page event. | `app.queue_sync`, `server.session_subscribe`, `server.http_request` | Keep available, but do not let them define product health by themselves. |

`server.turn.duration_ms` is workload telemetry. It measures the full wall-clock duration of an agent turn. A long turn can mean the agent is handling a large task, running tools, editing files, waiting on tests, or processing a large context. Treat it as a problem only when it combines with missing progress signals, high first-token latency, stuck tool calls, errors, blocked asks, or disconnected clients.

Turn and tool events carry a required `runtime` tag: `oppi` (classic SDK), `durable` (live durable engine: `serverDurable` and no Pi session file), or `pi-tui` (terminal mirror). They also carry the exact session-configured `provider` and `model` route when the session already has a canonical `provider/modelId`, and `thinking` when the configured reasoning level is one of Pi's known levels. Provider fallback or per-response reasoning changes can differ from those configured-route tags. `server.tool_call` pairs concurrent calls by `toolCallId`; an end without a matching start records the call without `duration_ms`, and starts without an end are discarded at turn end. A failed turn is `server.turn` with `status=error` and an `error_kind`. These events never include tool arguments, output, or file paths. `npm run telemetry:review -- --models` compares observed TTFT, turn and tool latency, call frequency, token use, total observed cost/output divided by tool calls, and mechanical error rates; the cost/output ratios are route-level efficiency indicators, not costs attributable to individual tools. A `status=ok` tool call means the tool finished without a mechanical error; it does not mean the agent completed the accepted task correctly.

## Experience events that belong on the front page

The front page should focus on events that directly map to user experience. Keep low-level events available for drill-down, but do not let them define the product health story. Series are `<event>.<field>`; the catalog holds each SLO.

### App and session responsiveness

| Event | Why it matters |
| --- | --- |
| MetricKit app launch | Daily time-to-first-draw and resume histograms; the client has no per-launch event. |
| `app.workspace_load` | Time until the workspace screen is usable. |
| `app.session_load` | Time from selecting a session to chat content visible. |
| `app.session_switch` | Session row tap-to-content latency. |
| `app.thread_load` | Time from opening a thread until its snapshot is applied. |
| `app.ttft` | User-perceived time to first assistant response token. |
| `app.fresh_content_lag` | Delay between new stream content and visible timeline freshness. |

### Connection and queue reliability

| Event or source | Why it matters |
| --- | --- |
| `app.ws_wait` | Client wait before commands can use the focused session stream; `result` says whether it was already connected, connected, or timed out. |
| `server.ws_handshake` | Server-side WebSocket upgrade latency, by `stream`. |
| `server.session_subscribe` | Server session subscribe/catch-up path latency. |
| `app.queue_sync` | Time to refresh queued steer/follow-up state. |
| `app.message_queue_ack` | Time from a busy send to server acknowledgement. `intent` is the composer's steer or follow_up; a turn that already ended prompts it normally. |
| `app.message_queue_stale_drop` | User input was dropped because the client had stale session state. |
| `app.app_event_stream_connect` | Time until global app updates, attention cards, and session list events are live. |
| `app.app_event_stream_reconnect` | Global app-event stream reconnects, by reason. |
| `app.app_event_stream_decode_error` | Global app-event stream payload/schema failures. |
| `server.ws_ping_timeout` | Dead connection detection. |
| Client logs: `WebSocket`, `AppEventStream`, `Network` | Reconnect storms, HTTP 1011s, POSIX disconnects, endpoint changes, and app-event stream failures. |

### Attention and media interactions

| Event | Why it matters |
| --- | --- |
| `app.ask_response` | How long the visible ask card blocked the agent before answer or ignore. |
| `app.media_playback_start` | Time from player setup to playable video or audio. Inline Markdown video sets up the player on the play tap, so it measures tap to ready. |
| `app.media_playback_error` | User-visible media preview/player failures by media kind and phase. |
| `app.voice_playback_start` | Startup latency for voice replies and replayable voice media, by source and mode. |
| `app.voice_playback_error` | Voice playback failures by source and phase. |
| Client logs: `MediaPlayback` | Playback/source failures with privacy-safe kind, source, phase, mode, and error class. |

### Timeline rendering and scrolling

| Event | Why it matters |
| --- | --- |
| `app.timeline_apply` | Snapshot/reducer apply time during streaming. |
| `app.timeline_layout` | UIKit layout cost during streaming. |
| `app.cell_configure` | Row rendering cost, especially large tool output rows. |
| `app.markdown_streaming` | Markdown streaming parse/build/apply cost. |
| `app.timeline_jank` | `jank_pct` of render cycles over frame budget, with the raw `cycles` and `hitches`. |

### Dictation and voice input

| Event | Why it matters |
| --- | --- |
| `app.dictation_setup` | Time from starting dictation to recording, with each setup phase as a field. Failed and cancelled setups carry only `total_ms`. |
| `app.dictation_first_result` | Time until the user sees first transcript feedback. |
| `app.dictation_end` | Stop-to-final latency, take length, preview/final delta, and loudest input level (near 0 means silence). |
| `app.dictation_capture_error` | Capture failures while dictating. |
| `app.live_voice_leftover_call` | A CallKit call iOS kept after Live Voice ended. |
| `server.dictation_finalize` | Backend STT latency and real-time factor, and total finalize time; `status=error` is a failed final STT. |
| `server.dictation_stream_error` | The dictation stream refused a connection or message. |

### Resource health and crash diagnostics

| Event or source | Why it matters |
| --- | --- |
| `app.device_resources` | Client CPU (all threads), memory footprint, available memory (low is bad), and thermal state every 10 s, tagged by screen, stream state, agents, and voice. |
| `app.memory_warning`, `app.foreground` | App size when iOS warns about memory and when it returns to the foreground. |
| `app.main_thread_stall_detected`, `app.main_thread_stall_recovered` | Watchdog stalls with footprint and duration. |
| `server.resources` | Server CPU, memory, event-loop delay (`event_loop_max_ms` is the release gate; `event_loop_p99_ms` is the ungated trend), sessions, and WebSocket connections. |
| MetricKit diagnostics | Crashes, hangs, CPU exceptions, disk-write exceptions, and app-launch diagnostics. |
| Client logs | Redacted diagnostic context for what happened before failure. |

## Lifecycle and hang correlation

The Apple client persists a bounded diagnostic context locally so a later MetricKit payload can be tied to what the app was doing. The context can include session, workspace, and active-server IDs; a coarse screen label; scene phase; the latest lifecycle step; focused-stream state; and large timeline-payload counts and sizes. It does not include prompt, response, tool, URL, or file-path content.

A release-build watchdog probes the main thread once per second while the app is active. A probe that cannot run within 700 ms records a stall sequence, threshold, timestamp, and current memory footprint. Recovery records the measured duration. Repeated notices for the same stall are limited to one every two seconds. The watchdog remains available for ten seconds after the app enters the background so background-transition hangs can retain their final lifecycle step.

Scene transitions record ordered steps around restoration, background keep-alive, audio transport, and graceful connection close. Background steps, watchdog detections and recoveries, and MetricKit diagnostic notices force the client-log queue to flush in submission order.

MetricKit usually delivers crash and hang diagnostics after the affected process has ended. On the first diagnostic-context write in a new process, Oppi rotates the saved context into a previous-process slot. MetricKit diagnostic serialization uses that previous-process context, falling back to the current context only when no previous snapshot exists.

All remote upload rules still apply: public builds upload this context only when **Send Diagnostics to Server** is enabled, and the server stores it only in the telemetry files above. Use `telemetry:client-logs` to review lifecycle and watchdog events. The corresponding MetricKit JSONL record keeps the bounded context in its summary and raw `oppiDiagnosticContext` object.

## Navigation breadcrumbs

Category `Navigation`, level `info`. These are user-driven events, a handful per minute, and they flush so a crash shortly afterward still has the route. They do not include prompt text, file contents, or paths.

| Message | When | Metadata |
| --- | --- | --- |
| `Presentation changed` | `AppNavigation.setWorkspaceNavigationPresentation` actually switches stack↔split | `from`, `to`, `horizontalSizeClass`, `verticalSizeClass`, `windowWidth`, `windowHeight`, `sessionRoutePreserved`, and `sessionId` when a session was visible. Size classes are `compact`, `regular`, or `unspecified`. Window size is the measured point size, or `unmeasured`. `sessionRoutePreserved` is `true` only when the same session id is still the visible route after the swap. |
| `Route changed` | Diagnostic-context hooks in `OppiApp` (`root` appear, launch phase, onboarding, Quick Session, workspace filter, workspace stack depth, stack destination, split destination, split detail depth) | `screen`, `previousScreen` (`none` on the first snapshot), `stackDepth` (the screens pushed on the stack shell; the screens pushed on the split detail column plus one when a split detail target is set), `presentation` (`stack` or `split`), `sessionId`, `workspaceId`. Hooks that fire in the same turn collapse to the final snapshot. An unchanged snapshot does not log. A split detail push logs when the depth changes even if the screen token does not. |
| `Quick Session presented` | A control sets `showQuickSession` | `source` is `session_list_bar`, `workspace_bar`, `thread_bar`, `agents`, or `intent` (App Intent / control). `screen` and `presentation` are the surface underneath, captured before the flag flips. |
| `Chat appeared` / `Chat disappeared` | `ChatViewController` appear and disappear | `sessionId`, `presentation`, `shellSwapRemount`, and `footprintMB` (phys_footprint, same reader as Session loaded). Appear sets `shellSwapRemount` from the existing shell-swap handoff (same session, other shell, within its departure window). Disappear sets it when the chat leaves under a different presentation than it mounted with. Appear also sets `sincePreviousMountMs` when this session mounted earlier in the process. |

`npm run telemetry:client-logs` prints a Builds breakdown. Each upload counts as `buildNumber@gitCommit` when the commit is present.

## Build identity

Debug and Release iOS builds stamp `OPPIGitCommit` through Info.plist preprocessing (`clients/apple/scripts/stamp-git-commit.sh`, wired from `project.yml`). A later `ProcessInfoPlistFile` copies the source plist over any post-build edit, so the script writes a prefix header and the processed plist expands it. The value is a 12-character git SHA, plus `-dirty` when the worktree is not clean. The script fails the build if git cannot read the checkout (`SRCROOT/../..`, or `OPPI_REPO_ROOT`). It does not stamp a placeholder. A missing or undefined `OPPI_GIT_COMMIT_VALUE` fails Info.plist preprocessing. The header is rewritten only when the stamp changes, so an unchanged commit does not reprocess Info.plist.

Every lane that compiles the Oppi target runs in a git checkout with that root: local `sim-pool`, device install, release builds, TestFlight archive, the pre-push Apple gate, and Xcode Cloud. Xcode Cloud may refuse the clone as dubious ownership; the stamp script marks the checkout safe for the read instead of skipping the stamp. No Oppi compile lane builds without git.

Client-log, app-event, and MetricKit uploads store that value (`client.gitCommit`) next to `appVersion` and `buildNumber` when it is a short SHA or a SHA with `-dirty`. The client omits any other stamp. The server drops any other string, including `unknown`, so a bad stamp cannot store a path. A client that omits the field still uploads.

## Informational events policy

Informational events are useful for debugging, but they must not drown out the experience story.

An event belongs on the front page only when it has all of these:

1. A user-visible question it answers.
2. A unit and owner.
3. A bounded tag set.
4. A release threshold, trend, or explicit investigation use.
5. Enough context to debug, usually `sessionId`, `workspaceId`, and low-cardinality tags.

Keep informational events when they are low-volume or needed for drill-down. Aggregate, sample, demote, or remove them when they are high-volume and do not affect a release decision.

Server events whose catalog entry declares `storage.aggregate` are folded before storage: for a `sum` field the stored value is the total over the roughly one-minute flush window, so dashboards should sum it, not count rows; for a `max` field (`server.broadcast_fanout.subscribers`) it is the window's peak.

Current handling guidance:

| Pattern | Action |
| --- | --- |
| Per-message counters such as `server.ws_message_sent` | Keep for drill-down, sum-aggregated by stream and message type instead of one record per frame. |
| Ephemeral UI counters | Keep only if they explain a UX event; otherwise sample or summarize by session. |
| Server HTTP timings (`server.http_request`) | Promote only route groups that affect visible UX. Fast successful health/stats/capability/navigation/session-poll/telemetry-upload routes are omitted (`http-request-metrics.ts`). |
| Server drill-down gauges such as `server.broadcast_fanout` | Max-aggregate by bounded tags; use peaks for diagnostics instead of raw counts. |
| Resource snapshots such as active-session peak or event-ring fill | Fields of `server.resources`, not separate events. |
| Windowed counters such as `app.coalescer_window` | Aggregate over a larger window and drop tiny partial drain windows; keep them as drill-down, not front-page rows. |
| Render drill-down such as `app.render_strategy` | Keep signposts for every operation, but upload only non-trivial events (catalog `emit` floor). |
| Routine commands such as successful `get_queue` | Keep errors, cancellations, and slow ones (catalog `emit` rule); rely on queue UX events for the normal success path. `status=error` is a user-visible failure, not a cancelled or superseded refresh. |
| Server token and cost usage (`server.turn_usage`) | Sum-aggregated before storage. |
| Client session-size snapshots (`app.session_usage`) | Emit only stable non-empty snapshots; treat them as latest/max capacity diagnostics, not per-update events. |
| Rare failures | Fold into the timing event as `status`/`error_kind`, or one error event with a `reason`, rather than many near-zero standalone events. |
| Stale or redundant events | Delete them from the catalog. |

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

The optional Grafana stack imports the v2 event files into SQLite and serves three dashboards: Release Preflight, Server Health, and Model Routing.

```bash
cd server
npm run telemetry:grafana:up
```

The importer (`server/scripts/manual/telemetry-import-sqlite.mjs`, parser version 7) writes every event of `app-events-*` and `server-events-*` into one `events` table, plus MetricKit payloads into `metrickit_payloads`:

| Column | Content |
| --- | --- |
| `ts_ms`, `origin`, `name` | The record's `ts`, origin (`app` or `server`), and catalog event name. Indexed on `(name, ts_ms)`. |
| `session_id`, `workspace_id` | The record's IDs. |
| `client_kind`, `app_version`, `build_number`, `git_commit`, `device_model` | From the record's `client` envelope; NULL on server events. |
| `fields_json`, `tags_json` | The record's `fields` and `tags` objects. |

Panels select one event and read its numbers and tags with `json_extract`:

```sql
SELECT CAST(ts_ms / 1000 AS INTEGER) AS time, json_extract(fields_json, '$.duration_ms') AS value
FROM events
WHERE name = 'app.trace_fetch'
  AND json_extract(tags_json, '$.status') = 'ok'
  AND ts_ms BETWEEN $__from AND $__to
```

Read each event the way its catalog entry stores it:

- Events with `storage.aggregate` (`server.turn_usage`, `server.ws_message_sent`, `server.ws_message_received`, `server.broadcast_fanout`): a row is one flush window. Use `SUM` of a `sum` field and `MAX` of a `max` field; the row count is windows, not events.
- Every other event is one row per occurrence: percentiles, `AVG`/`MAX` of the field, and `COUNT(*)` for the number of occurrences. Do not treat the count as request volume when the emitter omits fast successful routine routes (`server.http_request`).
- Tag values come from the catalog. `status` is the mechanical outcome (`ok`, `error`, `cancelled`, `timeout`); an SLO-like panel filters like the catalog `slo.where` (for example `app.trace_fetch` over `status=ok`). Rendering panels draw the 120 Hz frame budget (8.3 ms).
- An optional field is absent, not 0, when the occurrence did not measure it; filter `IS NOT NULL` before averaging.

`telemetry:review -- --http` reads raw `server.http_request` events: `duration_ms` p50/p90/p99, event count, and `status_code >= 400` rate, plus `response_bytes` p50/p90/max, by method and `path_pattern`. Percentiles are nearest-rank.

`app.thread_load` has no release SLO. `app.workspace_load` (TM99 1000 ms) and `app.session_switch` (TM99 600 ms) were gated from observed headroom; thread load had no installed-app samples to set a threshold against. The release gate for event-loop stalls is `server.resources.event_loop_max_ms` (TM99 100 ms), which sits between the 2026-10-06 TM99 of 50 ms and the 2026-10-07 TM99 of 111 ms; `event_loop_p99_ms` is a trend, not a second gate.

Importer notes:

- reads `app-events-*`, `server-events-*`, and `metrickit-*` JSONL from `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/`; pre-catalog files are not read and a line that is not a v2 record is skipped
- leaves the legacy tables (`chat_metric_samples`, `server_metric_samples`, `server_ops_metric_samples`) of an existing database in place and unused; a new database does not create them, and nothing translates legacy files into events, so dashboard history starts at the cutover
- writes SQLite into a Docker-managed volume for Grafana; Grafana opens it read-write so SQLite WAL-mode read queries can create sidecar shared-memory files
- can also run manually with `npm run telemetry:import`
- normalizes append-only daily JSONL files incrementally, and reimports a file when the importer parser version changes

The dashboards and the provisioned alert rules (`server/docker/grafana/provisioning/alerting/alert-rules.yml`) are checked against the catalog by `npm run check`: every event, `fields_json` key, `tags_json` key, and tag literal they use must exist in the catalog, and every query must run against the importer's schema. `npm run telemetry:grafana:check` (a dev tool) then runs every panel query against a live Grafana and lists errors and empty panels.

See `server/README.md` for the full dashboard runbook.

## Adding or changing an event

Before adding an event, answer these questions in the code review:

1. What user experience question does this event answer? (It becomes the catalog `description`.)
2. Is it a front-page event, drill-down, or temporary investigation event?
3. What are its fields and their units?
4. Which tags does it carry, and are they bounded?
5. Does it carry session/workspace context when that is useful?
6. What is the removal or promotion trigger if it is temporary?

Implementation rules:

- Declare the event in `server/src/telemetry/catalog.ts` first: fields with units, tags (reuse a vocabulary key with the same meaning, or add a key with one meaning), `group`, and any `emit`, `storage`, and `slo`.
- `app.*` events: run `bun server/scripts/generate-telemetry-catalog.ts` and record the generated struct with `Telemetry.record`. Server events: call `ServerTelemetry.record` with the catalog types.
- `cd server && npm run check` runs `scripts/check-telemetry.ts`; fix every invariant it reports and commit the regenerated Swift.
- Prefer log lines for raw platform error details such as `NSURLErrorDomain`, HTTP status, or WebSocket close reason; events carry bounded counts, durations, and ratios.
- Update tests when an event's behavior changes; do not pin event names or wording.
- Prefer fewer, better-shaped events over broad logging-by-event.
