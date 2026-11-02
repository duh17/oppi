# Telemetry and diagnostics

> **What belongs here:** telemetry owners, privacy gates, storage, the catalog's invariants, and review commands. Event semantics live in the catalog (`server/src/telemetry/catalog.ts`); the event tables below are generated from it. Standard and budgets: [`dev/README.md`](README.md#what-belongs-in-dev).

Oppi records diagnostics to answer one question: does the app feel fast, reliable, and safe while someone supervises a Pi session? Every event (name, fields and units, tags, emit policy, storage, group, SLO) is declared once in the catalog. Out of scope: Pi's own install telemetry, provider billing, and raw session content.

## Review commands

From `server/`:

```bash
npm run telemetry:review -- --days 1 --wide   # also --http, --models
npm run telemetry:client-logs -- --days 1 --limit 30
npm run telemetry:metrickit -- --days 14 --limit 50
npm run telemetry:server-log -- --days 1 --limit 30
npm run diagnostics:review -- --days 1
npm run telemetry:review:gate                 # release gate
npm run telemetry:grafana:up                  # http://localhost:13001, admin/admin
```

Dashboards: Release Preflight (experience), Server Health (resources and server ops), Model Routing (provider/model/runtime workload). Runbook: `server/README.md`.

## Privacy model

- Public iOS builds (`OPPI_TELEMETRY_MODE=public`) upload only when **Settings → Privacy & Security → Send Diagnostics** is on; internal and debug builds (`internal`) upload automatically. Uploads go only to the configured Oppi server; no external crash-reporting SDK is linked.
- The server enforces `OPPI_TELEMETRY_MODE` too: `public`, `release`, `prod`, `off`, and equivalents reject uploads with 403.
- Telemetry never contains prompt text, assistant output, tool arguments, command output, dictation transcripts, relay URLs or hosts, IP addresses, tokens, tickets, node or endpoint ids, secrets, raw URLs, or local paths.
- Allowed: low-cardinality ids (session, workspace, app instance, boot), bounded tags, numeric timings, counts, ratios, bytes, sanitized MetricKit summaries, coarse screen and lifecycle context, redacted client logs.

## Upload channels and storage

| Channel | Endpoint | Stored at (`<OPPI_DATA_DIR>/diagnostics/telemetry/`) |
| --- | --- | --- |
| App events | `POST /telemetry/events` | `app-events-YYYY-MM-DD.jsonl` |
| MetricKit | `POST /telemetry/metrickit` | `metrickit-YYYY-MM-DD.jsonl` |
| Client logs | `POST /telemetry/client-logs` | `client-logs-YYYY-MM-DD.jsonl` |
| Server events | local writer | `server-events-YYYY-MM-DD.jsonl` |
| Server log | local | `<OPPI_DATA_DIR>/server.log` |

- All three uploads carry one `client` envelope (`kind: "ios" | "mac"`, versions, `gitCommit`, `deviceModel`, ids); an upload without a valid `client.kind` is 400. MetricKit and client-log files keep their pre-envelope stored shape.
- Daily files are named by the server's UTC write date; readers filter by each record's `ts`.
- Retention: MetricKit 14 days (`OPPI_METRICKIT_RETENTION_DAYS`), app events and client logs 14 (`OPPI_CHAT_METRICS_RETENTION_DAYS`), server events 30 (`OPPI_SERVER_METRICS_RETENTION_DAYS`). Daily caps: `OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES`, `OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES`. The server cap excludes `server.resources`, so ops events cannot starve the Server Metrics page and samples cannot use up the ops budget.
- Pre-catalog files (`chat-metrics-*`, `server-ops-metrics-*`, `server-metrics-*`) are neither written nor read; retention prunes them.

## Server resource sampling

- `ServerResourceSampler` runs only while `serverMetrics.enabled` is true (default false): off means no timer, histogram, host reads, or samples, so Server Health's resource panels and the `server.resources.event_loop_max_ms` gate input stay empty. The switch is latched at startup; `PUT /server/metrics/settings` toggles it live, `oppi config set` needs a restart.
- Each sample is one `server.resources` event written at once. `host-resource-probe.ts` adds host or container readings: a Linux process is a container when `/.dockerenv`, `/run/.containerenv`, `$container`, or `$KUBERNETES_SERVICE_HOST` exists, and then reads its cgroup like `docker stats`. A container whose cgroup cannot be read omits CPU and memory rather than reporting the machine; any failed read is omitted, never estimated. Process `cpu_total_pct` is a share of one core and can exceed 100.
- `GET /server/metrics?range=1h|24h|7d|30d` buckets the `server.resources` events from the daily files (`server-metrics-history.ts`); there are no derived files, and the response keeps its pre-catalog shape.

## Telemetry catalog

`server/src/telemetry/catalog.ts` is pure data and types; everything else derives from it or is checked against it:

- `POST /telemetry/events` (`routes/telemetry.ts`, `telemetry/validate.ts`) validates name, origin, fields and units, tags, and emit policy, dropping failures with counts by reason.
- `ServerTelemetry.record(name, fields, tags, ids?)` takes catalog types, so an unknown event, field, tag, or value does not compile; the collector (`telemetry/server-telemetry.ts`) folds `storage.aggregate` events per 60 s window.
- `server/scripts/generate-telemetry-catalog.ts` writes `clients/apple/Oppi/Core/Telemetry/TelemetryCatalog.generated.swift`; never edit it by hand.
- `server/scripts/check-telemetry.ts` (in `npm run check`) enforces the invariants below, fails on stale generated Swift or stale tables on this page, and checks dashboards, alert rules, importer, and review script against the catalog.

### Naming and units

- Event names are `<origin>.<snake_case>` (`app.*`, `server.*`). One logical event is one record: values measured together are fields of one event.
- Units: `ms`, `count`, `bytes`, `mb`, `pct` (0–100), `ratio` (0–1), `usd_micros`, `bool`; field names end with the unit suffix (`count` and `bool` have none). An absent optional field is never written as 0.
- Numbers and ids are never tags.
- `emit` rules drop out-of-range events; the generated Swift applies them before building anything, and ingest applies them again. `slo` sets a TM99 threshold on one field (optionally `where` tags match); rendering SLOs use the 120 Hz budget (8.3 ms).
- Removed events are deleted from the catalog, not retired.

### Tag vocabulary

Each tag key has exactly one meaning and one kind (`TAGS`): `enum` (closed, narrowable per event), `bucket` (shared size classes), or `name` (bounded identifier, 1–128 of `A-Za-z0-9._/:@-`, else `unknown`).

- `name` values shaped like a location are stored as `unknown`, by rules that are data in the catalog (`NAME_LOCATION_RULES`), so the server (`looksLikeLocation`) and Swift (`TelemetryName`) apply the same ones; `protocol/telemetry-name-tags.json` is the shared accept/reject list. This is defence in depth: a bare hostname or relative path looks like any identifier, so **every source of a `name` tag must be bounded** (a constant, an enum-like value, or a value chosen from a closed set). Never feed one a configured endpoint, URL, or path; the streaming STT provider reports the constant `streaming`, never its endpoint.
- Shared meanings: `status` is the mechanical outcome (`ok`, `error`, `cancelled`, `timeout`); `result` an event-specific outcome; `reason` why it happened; `error_kind` the one coarse error vocabulary (never a type name, text, or code); `phase` the step; `stream` the server WebSocket stream; `transport` `paired`/`lan`/`unix`/`local`; `provider`/`model`/`thinking`/`runtime` the session's configured route.
- Keys that once carried two meanings were split and `check-telemetry.ts` refuses the old ones (WebSocket `path` → `stream`, device `stream` → `stream_state`, `source` → `trigger`/`playback_source`/`load_source`/`origin_surface`, `outcome`/`success` → `status`, and the rest listed in `check-telemetry.ts`). The raw server `host` is never a tag.

### Wire format and storage

- An upload is `{ generatedAt, client, events: [{ ts, name, fields, tags?, sessionId?, workspaceId? }] }`, at most 500 events (extras dropped as `over_batch_limit`); the response counts drops by reason (`malformed`, `unknown_event`, `invalid_tag_value`, `emit_policy`, …). A dropped event cannot succeed on retry.
- `protocol/telemetry-events-upload.json` is a golden upload encoded by the generated Swift: server ingest must accept every event, and `TelemetryEventsUploadContractTests` fails on any byte difference.
- Each stored event is one JSONL line `{ v: 2, ts, origin, name, fields, tags, sessionId?, workspaceId?, client? }`. An aggregated record stores the window's sum or max and no event count, so an event that needs one declares a count field.

### Apple client recording

- One path: `Telemetry.record(<generated struct>, sessionId:, workspaceId:)` (`clients/apple/Oppi/Core/Telemetry/Telemetry.swift`). It applies `emit` rules first (the catalog is the only place a threshold lives), drops non-finite fields (one NaN fails JSON encoding for the whole batch), and hands off to `TelemetryEventUploader` (1000 buffered, batches of 50). A 2xx never requeues; dropped events are logged and never resent. The server logs `telemetry_events.dropped` once per reason and build.
- `TelemetryContext` is the one provider of ambient `screen`, `stream_state`, `agents`, `voice`; unknown is `unknown`, never absent.
- `TelemetryErrorKind.classify` is the one mapping from errors to `error_kind`. `OppiCore` names its vocabularies with enums whose raw values are catalog values, and a test fails on any case without a catalog counterpart.
- Numbers belong in events, not log lines.

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

## Reading events

- Catalog `group` places each event in a review group. Front-page events answer a user-visible question with a unit, owner, bounded tags, and a threshold or trend; drill-down events explain them and never define product health by themselves.
- `server.turn.duration_ms` is workload, not latency: a long turn is a problem only alongside missing progress, high TTFT, stuck tools, errors, blocked asks, or disconnected clients. Turn and tool events carry a required `runtime` tag (`oppi`, `durable`, `pi-tui`) and the configured route. `server.tool_call` pairs calls by `toolCallId`. A `status=ok` tool call means no mechanical error, not a correct task. Neither ever carries tool arguments, output, or paths.
- `storage.aggregate` events (`server.turn_usage`, `server.ws_message_sent`, `server.ws_message_received`, `server.broadcast_fanout`) store one row per flush window: `SUM` a `sum` field, `MAX` a `max` field, and never count rows as events. `server.http_request` omits fast successful routine routes (`http-request-metrics.ts`), so its count is not request volume. Filter optional fields `IS NOT NULL` before averaging.
- Release gates: `app.workspace_load` TM99 1000 ms, `app.session_switch` TM99 600 ms, and `server.resources.event_loop_max_ms` TM99 100 ms (`event_loop_p99_ms` is a trend, not a second gate).

## Lifecycle and hang correlation

- The client persists a bounded diagnostic context (ids, coarse screen, scene phase, last lifecycle step, stream state, large-payload counts), never content, URLs, or paths. On the first write in a new process it rotates the saved context into a previous-process slot, and MetricKit serialization uses that slot, because MetricKit delivers crash and hang diagnostics after the process ended.
- A release-build watchdog probes the main thread once per second while active (700 ms threshold) and for ten seconds after backgrounding. Background steps, watchdog events, and MetricKit notices force the client-log queue to flush in order.
- `Navigation` breadcrumbs (`Presentation changed`, `Route changed`, `Quick Session presented`, `Chat appeared`/`Chat disappeared`, `Link opened`) flush so a crash shortly after still has the route; they carry no prompt, file contents, or paths.

## Build identity

`clients/apple/scripts/stamp-git-commit.sh` (from `project.yml`) stamps `OPPIGitCommit` through a prefix header that Info.plist preprocessing expands, because `ProcessInfoPlistFile` overwrites post-build plist edits. The value is a 12-character SHA, plus `-dirty`. The script fails the build when git cannot read the checkout and never stamps a placeholder; on Xcode Cloud it marks the checkout safe rather than skip. Every Oppi compile lane runs in a git checkout. The server stores `client.gitCommit` only when it is a short SHA (optionally `-dirty`), so a bad stamp cannot store a path.

## Local dashboards and importer

- `server/scripts/manual/telemetry-import-sqlite.mjs` (parser version 7) imports `app-events-*` and `server-events-*` into one `events` table (`ts_ms`, `origin`, `name`, ids, client columns, `fields_json`, `tags_json`; indexed on `(name, ts_ms)`) plus `metrickit_payloads`. Non-v2 lines and pre-catalog files are skipped; legacy tables stay unused, so dashboard history starts at the catalog cutover. A parser version change reimports files.
- Grafana opens the SQLite volume read-write so WAL-mode reads can create shared-memory sidecars.
- Dashboards and alert rules (`server/docker/grafana/provisioning/alerting/alert-rules.yml`) may use only catalog events, fields, tags, and tag values, and every query must run against the importer schema (`npm run check`). `npm run telemetry:grafana:check` runs every panel against a live Grafana.

## Adding or changing an event

1. Declare it in `server/src/telemetry/catalog.ts` first: the user question it answers (its `description`), fields with units, bounded tags (reuse a key with the same meaning or add one with one meaning), `group`, and any `emit`, `storage`, `slo`. Say whether it is front-page, drill-down, or temporary, and what removes or promotes it.
2. `app.*`: run `bun server/scripts/generate-telemetry-catalog.ts` and record the generated struct; server: `ServerTelemetry.record`.
3. `cd server && npm run check`, fix what `check-telemetry.ts` reports, and commit the regenerated Swift and tables.
4. Raw platform error details (`NSURLErrorDomain`, HTTP status, close reasons) go in log lines; events carry bounded numbers. Prefer fewer, better-shaped events; aggregate, sample, demote, or delete high-volume ones that inform no release decision. Tests never pin event names or wording.
