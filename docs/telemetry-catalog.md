# Oppi Telemetry Catalog (Source of Truth)

This document is the canonical inventory for Oppi diagnostics telemetry.

## Build-mode matrix

| Build mode | How it is set | `OPPI_TELEMETRY_MODE` default | Remote diagnostics upload |
|---|---|---:|---|
| Debug (local dev) | Xcode Debug config | `internal` | Enabled (unless overridden to `public`) |
| Internal QA / dogfood | Explicit env override in build/run | `internal` | Enabled |
| TestFlight | `ios/scripts/release.sh` | `internal` (`TESTFLIGHT_TELEMETRY_MODE` default) | Enabled by default |
| Public App Store | Release config (override to `public` for privacy mode) | `internal` | Enabled by default |

## Canonical config flags

| Flag | Layer | Purpose | Default |
|---|---|---|---|
| `OPPI_TELEMETRY_MODE` | iOS + server | Single gate for remote diagnostics transport | Debug=`internal`, Release=`internal` |
| `SENTRY_DSN` | iOS | Enables Sentry when non-empty **and** telemetry mode allows uploads | empty |
| `TESTFLIGHT_TELEMETRY_MODE` | release script | Convenience wrapper passed to `OPPI_TELEMETRY_MODE` during TestFlight archive | `internal` |
| `OPPI_METRICKIT_RETENTION_DAYS` | server | MetricKit JSONL retention window | `14` |
| `OPPI_CHAT_METRICS_RETENTION_DAYS` | server | Chat metrics JSONL retention window | `14` |

## Channel inventory

| Channel | Transport | Payload class | Owner | Gated by `OPPI_TELEMETRY_MODE` |
|---|---|---|---|---|
| Sentry | Sentry SDK | Crash/error/tracing/breadcrumb diagnostics | iOS runtime | Yes (plus DSN required) |
| MetricKit | `POST /telemetry/metrickit` | Sanitized MetricKit payload envelopes | iOS + server | Yes |
| Chat metrics | `POST /telemetry/chat-metrics` | Numeric chat/stream/render/voice samples | iOS + server | Yes |
| Client logs | `POST /workspaces/:workspaceId/sessions/:sessionId/client-logs` | Structured debug log batches | iOS + server | Yes |

Server storage paths:
- MetricKit: `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`
- Chat metrics: `<OPPI_DATA_DIR>/diagnostics/telemetry/chat-metrics-YYYY-MM-DD.jsonl`
- Client logs: `<OPPI_DATA_DIR>/client-logs/<sessionId>.jsonl`

## Chat metric catalog

All chat metrics are emitted from iOS and validated by server allowlists in `server/src/types.ts` and `server/src/routes/telemetry.ts`.

| Metric name | Unit | Primary emitter(s) | Typical tags | SLO / use |
|---|---|---|---|---|
| `chat.ttft_ms` | `ms` | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift` | none | Track first-token responsiveness drift |
| `chat.catchup_ms` | `ms` | `ChatSessionManager.swift` | `result` (`no_gap`,`applied`,`ring_miss`,`fetch_failed`,`seq_regression`) | Reconnect/catch-up latency budget |
| `chat.catchup_ring_miss` | `count` | `ChatSessionManager.swift` | none | Ring-buffer miss rate |
| `chat.timeline_apply_ms` | `ms` | `ios/Oppi/Features/Chat/Timeline/ChatTimelinePerf.swift` | `items`,`changed` | UI apply jank guardrail |
| `chat.timeline_layout_ms` | `ms` | `ChatTimelinePerf.swift` | `items` | UI layout jank guardrail |
| `chat.ws_decode_ms` | `ms` | `ios/Oppi/Core/Networking/WebSocketClient.swift`, `ChatSessionManager.swift` | `type`,`stage`,`transport` | Decode and main-thread handoff lag isolation |
| `chat.coalescer_flush_events` | `count` | `ios/Oppi/Core/Runtime/DeltaCoalescer.swift` | none | Burst-shaping observability |
| `chat.coalescer_flush_bytes` | `count` | `DeltaCoalescer.swift` | none | Burst payload sizing |
| `chat.inbound_queue_depth` | `count` | `WebSocketClient.swift` | none | Backpressure/high-water visibility |
| `chat.full_reload_ms` | `ms` | `ChatSessionManager.swift` | `traceEvents` | Full-history reload budget |
| `chat.fresh_content_lag_ms` | `ms` | `ChatSessionManager.swift` | `reason`,`cache`,`transport` | Time-to-fresh-content after entering session |
| `chat.cache_load_ms` | `ms` | `ChatSessionManager.swift` | `hit`,`events` | Cache load performance |
| `chat.reducer_load_ms` | `ms` | `ChatSessionManager.swift` | `source`,`events`,`items` | Timeline reduction/build cost |
| `chat.ws_connect_ms` | `ms` | `ChatSessionManager.swift` | `transport` | WS connect latency tracking by path |
| `chat.voice_prewarm_ms` | `ms` | `ios/Oppi/Core/Services/VoiceInputManager.swift` | `engine`,`locale`,`source`,`phase`,`status` | Voice prewarm readiness |
| `chat.voice_setup_ms` | `ms` | `VoiceInputManager.swift` | `engine`,`locale`,`source`,`phase`,`status`,`path` | Voice start pipeline latency |
| `chat.voice_first_result_ms` | `ms` | `VoiceInputManager.swift` | `engine`,`locale`,`source`,`phase`,`status`,`result_type` | Voice first-result latency |

## Privacy constraints

Never send as telemetry:
- prompt text
- assistant output
- tool arguments
- transcript content

IDs and low-cardinality diagnostics tags are allowed; content payloads are not.
