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
| `chat.ttft_ms` | `ms` | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift` | `provider`,`model` | Track first-response-token responsiveness drift, segmented by model |
| `chat.catchup_ms` | `ms` | `ChatSessionManager.swift` | `result` (`no_gap`,`applied`,`ring_miss`,`fetch_failed`,`seq_regression`) | Reconnect/catch-up latency budget |
| `chat.catchup_ring_miss` | `count` | `ChatSessionManager.swift` | none | Ring-buffer miss rate |
| `chat.timeline_apply_ms` | `ms` | `ChatTimelinePerf.swift` | `items`,`changed` | UI apply jank (threshold-gated: only emitted when >= 4ms) |
| `chat.timeline_layout_ms` | `ms` | `ChatTimelinePerf.swift` | `items` | UI layout jank (threshold-gated: only emitted when >= 2ms) |
| ~~`chat.ws_decode_ms`~~ | — | — | — | **Removed.** High-volume noise (32% of samples, almost always 0ms). |
| `chat.coalescer_flush_events` | `count` | `ios/Oppi/Core/Runtime/DeltaCoalescer.swift` | none | Burst-shaping observability |
| `chat.coalescer_flush_bytes` | `count` | `DeltaCoalescer.swift` | none | Burst payload sizing |
| `chat.inbound_queue_depth` | `count` | `WebSocketClient.swift` | none | Backpressure/high-water visibility |
| `chat.full_reload_ms` | `ms` | `ChatSessionManager.swift` | `traceEvents` | Full-history reload budget |
| `chat.fresh_content_lag_ms` | `ms` | `ChatSessionManager.swift` | `reason`,`cache`,`transport` | Time-to-fresh-content after entering session |
| `chat.cache_load_ms` | `ms` | `ChatSessionManager.swift` | `hit`,`events` | Cache load performance |
| `chat.reducer_load_ms` | `ms` | `ChatSessionManager.swift` | `source`,`events`,`items` | Timeline reduction/build cost |
| `chat.ws_connect_ms` | `ms` | `ChatSessionManager.swift` | `transport` | Legacy mixed connect/setup bucket (kept for overlap during migration) |
| `chat.stream_open_ms` | `ms` | `ios/Oppi/Core/Networking/ServerConnection.swift` | `transport`,`status` | Stream open phase latency (`streamSession` start -> WS connected) |
| `chat.subscribe_ack_ms` | `ms` | `ServerConnection.swift` | `transport`,`status`,`error_kind` | Subscribe command acknowledgement latency |
| `chat.queue_sync_ms` | `ms` | `ServerConnection.swift` | `transport`,`status`,`error_kind` | Initial queue sync (`get_queue`) latency |
| `chat.connected_dispatch_ms` | `ms` | `ChatSessionManager.swift` | `transport` | Connected-event dispatch lag into session loop |
| `chat.session_message_count` | `count` | `ios/Oppi/Core/Networking/ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative message count snapshots |
| `chat.session_input_tokens` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative input token snapshots |
| `chat.session_output_tokens` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative output token snapshots |
| `chat.session_total_tokens` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative total token snapshots |
| `chat.session_mutating_tool_calls` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative mutating tool call snapshots |
| `chat.session_files_changed` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative changed-file snapshots |
| `chat.session_added_lines` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative added-line snapshots |
| `chat.session_removed_lines` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Per-session cumulative removed-line snapshots |
| `chat.session_context_tokens` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Latest per-session context token usage snapshot |
| `chat.session_context_window` | `count` | `ServerConnection+MessageRouter.swift` | `provider`,`model` | Latest per-session context window size snapshot |
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
