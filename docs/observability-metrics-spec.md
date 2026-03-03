# Oppi Observability Metrics Spec (iOS + Server)

**Status:** Draft v1 (design)
**Last updated:** 2026-03-03
**Scope:** Internal diagnostics telemetry (`OPPI_TELEMETRY_MODE=internal`)

This document defines the target observability model for Oppi across iOS and server.

- `docs/telemetry-catalog.md` remains the **current implemented inventory**.
- This spec defines the **contract we are converging to** (metric quality, naming, ownership, and dashboards).

## 1) Goals

1. Measure the user experience we actually care about (speed + smoothness + reliability).
2. Split metrics so each number has one meaning (no overloaded latency buckets).
3. Make iOS and server metrics composable in one story (same journey, same language).
4. Keep privacy guarantees: diagnostics only, no conversation content, low-cardinality tags.

## 2) Non-goals

- Product analytics (feature funnels, retention cohorts, click tracking).
- Content-level telemetry (prompts, assistant output, tool args, transcripts).

## 3) Metric contract standard

Every metric definition must include:

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Dot namespaced (`chat.*`, `plot.*`, `server.*`, `ios.*`) |
| `unit` | yes | `ms` / `count` / `ratio` (expand only by explicit spec update) |
| `type` | yes | `experience`, `phase`, `capacity`, `stability` |
| `owner` | yes | `ios`, `server`, or `shared` |
| `emitter` | yes | concrete file/module |
| `description` | yes | one-sentence meaning |
| `required_tags` | yes | low-cardinality only |
| `optional_tags` | optional | low-cardinality only |
| `status` | yes | `active`, `planned`, `deprecated` |
| `dashboard_panel` | yes | panel name/id |
| `slo_target` | optional | p50/p95/threshold if actionable |

## 4) Tag taxonomy and rules

### 4.1 Canonical tag keys

Use only snake_case keys.

Core keys:
- `phase`
- `status`
- `transport` (`paired`, `lan`, `fallback`, `unknown`)
- `source` (entrypoint/source of flow)
- `result` (outcome enum)
- `path` (cold/warm/join path etc.)
- `error_kind` (coarse error class, not raw message)
- `provider` (model provider namespace)
- `model` (normalized model ID without provider prefix)

### 4.2 Rules

- Tags must be low-cardinality enums/booleans/small bounded sets.
- Session/workspace identifiers stay in dedicated fields, not ad-hoc tags.
- No free-form text tags.
- Server ingestion normalizes keys to snake_case and enforces limits.

## 5) Experience scorecard (headline metrics)

These are the metrics we track as product health.

| Metric | Layer | Status | Meaning | Initial target |
|---|---|---|---|---|
| `chat.fresh_content_lag_ms` | iOS | active | Enter session -> first confirmed fresh timeline state | p95 <= 2000ms |
| `chat.ttft_ms` | iOS | active | Send prompt -> first response chunk (thinking or text), segmented by `provider`/`model` | p95 <= 1200ms per provider/model |
| `chat.reconnect_recovery_ms` | iOS | planned | Disconnect detected -> stream healthy again | p95 <= 3000ms |
| `chat.voice_first_result_ms` | iOS | active | Voice start -> first transcript result | p95 <= 2500ms |
| `ios.app_hang_count` | iOS (MetricKit-derived) | planned | App hangs per session/day cohort | trending down |
| `ios.scroll_hitch_ratio` | iOS (MetricKit-derived) | planned | Hitch burden during chat-heavy sessions | trending down |

## 6) Stream/session decomposition (diagnostic metrics)

Current `chat.ws_connect_ms` is overloaded. We keep it temporarily, but split into explicit phases.

| Metric | Status | Meaning |
|---|---|---|
| `chat.ws_connect_ms` | active -> deprecated | Existing mixed metric (connect + setup + consumption delay) |
| `chat.stream_open_ms` | active | `streamSession()` start -> websocket usable |
| `chat.subscribe_ack_ms` | active | subscribe command sent -> ack received |
| `chat.queue_sync_ms` | active | initial `get_queue` roundtrip |
| `chat.connected_dispatch_ms` | active | connected decoded -> consumed in session loop |
| `chat.ws_decode_ms` | active | decode + hop/dispatch stage timing |
| `chat.inbound_queue_depth` | active | inbound queue depth high-water marks |

### Session usage counters (provider/model segmented)

These are cumulative per-session snapshots emitted from iOS session state updates.

| Metric | Status | Meaning |
|---|---|---|
| `chat.session_message_count` | active | cumulative message count for the session |
| `chat.session_input_tokens` | active | cumulative input tokens for the session |
| `chat.session_output_tokens` | active | cumulative output tokens for the session |
| `chat.session_total_tokens` | active | cumulative total tokens (`input + output`) |
| `chat.session_mutating_tool_calls` | active | cumulative mutating tool call count |
| `chat.session_files_changed` | active | cumulative unique changed file count |
| `chat.session_added_lines` | active | cumulative added line count |
| `chat.session_removed_lines` | active | cumulative removed line count |
| `chat.session_context_tokens` | active | latest context token usage snapshot |
| `chat.session_context_window` | active | latest context window size snapshot |

Required tags for session usage counters: `provider`, `model`.

Deprecation rule for `chat.ws_connect_ms`:
- keep while new split metrics are live for >= 2 release cycles
- remove from headline panels once split metrics are stable

## 7) Server observability baseline (new)

Server currently has strong logs but limited numeric latency series. Add these metrics first:

| Metric | Status | Meaning |
|---|---|---|
| `server.http_request_ms` | planned | route latency by route class (`sessions`, `stream`, `telemetry`, etc.) |
| `server.ws_subscribe_ack_ms` | planned | server-side subscribe processing latency |
| `server.stream_fanout_delay_ms` | planned | publish -> deliver lag in stream mux |
| `server.catchup_fetch_ms` | planned | session events catch-up fetch latency |
| `server.trace_load_ms` | planned | trace load/parse latency |
| `server.telemetry_ingest_ms` | planned | telemetry request parse + write latency |
| `server.telemetry_reject_count` | planned | reject rate by reason (`mode_disabled`, `invalid_payload`, etc.) |

## 8) Apple (MetricKit) operational metrics

MetricKit payloads are currently stored as envelopes. Promote key aggregates into queryable series:

| Metric | Status | Source |
|---|---|---|
| `ios.launch_cold_ms` | planned | MetricKit app launch metrics |
| `ios.launch_warm_ms` | planned | MetricKit app launch metrics |
| `ios.app_hang_count` | planned | MetricKit hang diagnostics |
| `ios.memory_peak_mb` | planned | MetricKit memory metrics |
| `ios.scroll_hitch_ratio` | planned | MetricKit animation/scroll hitch metrics |

## 9) Dashboard contract (single shared dashboard)

One dashboard (`Oppi Release Preflight`) with segmented rows:

1. **Experience** (headline p50/p95 + trend)
2. **Session stream phases** (connect decomposition)
3. **Voice**
4. **Rendering / timeline**
5. **Server health**
6. **Metric inventory** (with segment + sample counts)

Required panel behavior:
- show sample volume next to percentile charts
- filter by `build_number`, `transport`, and time range
- keep raw point view available; optional smoothed percentile overlays

## 10) Ownership and change process

Any metric add/change/remove requires:

1. Update this spec (`status`, meaning, owner, tags, panel).
2. Update implementation registry/contracts:
   - server metric registry (`server/src/types.ts`)
   - iOS enum/contracts (`ios/Oppi/Core/Services/MetricKitModels.swift`)
3. Add/adjust ingestion validation tests.
4. Add/adjust dashboard panel(s).
5. Add parity test to catch iOS/server drift.

## 11) Rollout plan

### Phase 1 (immediate)
- Split stream phase metrics on iOS (`stream_open_ms`, `subscribe_ack_ms`, `queue_sync_ms`, `connected_dispatch_ms`).
- Keep existing `ws_connect_ms` for overlap comparison.

### Phase 2
- Add baseline server latency/counter metrics listed in section 7.
- Add server panels to shared dashboard.

### Phase 3
- Extract MetricKit aggregates into first-class `ios.*` metrics.
- Add release guardrails on experience p95s.

---

## Appendix: current source-of-truth docs

- `docs/telemetry.md`
- `docs/telemetry-catalog.md`
- `docs/debug/ws-session-reentry-delay.md`
