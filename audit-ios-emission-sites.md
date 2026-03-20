# iOS Telemetry Emission Audit

Generated: 2026-03-20

All `ChatMetricsService.shared.record(...)` call sites in the iOS codebase. Every emission goes through the same pipeline: `ChatMetricsService` (actor) → batched upload to server via `APIClient.uploadChatMetrics`. Gated by `TelemetrySettings.allowsRemoteDiagnosticsUpload`. Flush interval: 10s or when 50 samples accumulate.

---

## 1. Connection & Transport Metrics

### 1.1 `chat.ws_connect_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:472-475` |
| **Emitter** | `ChatSessionTelemetry.recordWsConnect(...)` → `ChatSessionTelemetry.swift:53-57` |
| **Trigger** | First `.connected` server message received after WS open. Measures wall time from `wsOpenStartMs` (set at WS open) to the `.connected` message arrival. |
| **Tags** | `transport` (e.g. "paired", "direct") |
| **Threshold-gated** | No — always emitted on first `.connected` per connection. |
| **Volume** | Once per WebSocket connection (once per session connect or reconnect). |

### 1.2 `chat.stream_open_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/SessionStreamCoordinator.swift:140-151` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | Measures time from stream-open request to WS connected status. Emitted after `waitForConnectedStream(timeout: 10s)` completes or times out. |
| **Tags** | `transport`, `status` ("already_connected", "connected", "timeout") |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per `streamSession(...)` call (once per session subscription). |

### 1.3 `chat.subscribe_ack_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/SessionStreamCoordinator.swift:190-206` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | Measures time from subscribe command send to ack received (or error). Times out at 10s. |
| **Tags** | `transport`, `status` ("ok" or "error"), `error_kind` (on error) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per session subscription. |

### 1.4 `chat.connected_dispatch_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:450-455` |
| **Emitter** | `ChatSessionTelemetry.recordConnectedDispatchLag(...)` → `ChatSessionTelemetry.swift:59-63` |
| **Trigger** | `.connected` server message received. Measures lag between `inboundMeta.receivedAtMs` (WS receive loop timestamp) and MainActor dispatch time. |
| **Tags** | `transport` |
| **Threshold-gated** | No — always emitted (but only logged to ClientLog when ≥1000ms). |
| **Volume** | Once per `.connected` message (once per WS connection). |

### 1.5 `chat.queue_sync_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/SessionStreamCoordinator.swift:549-563` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | After `get_queue` command completes or errors during initial or deferred queue sync. |
| **Tags** | `transport`, `status` ("ok" or "error"), `phase` ("initial" or "deferred"), `error_kind` (on error) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | 1-2 per session connection (initial sync, optionally a deferred retry). |

### 1.6 `chat.message_queue_ack_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/MessageSender.swift:429-439` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | After a sent command (prompt/steer/follow_up) receives its ack or errors. Measures wall time from command send to ack. |
| **Tags** | `command`, `status` ("ok" or "error"), `error_kind` (on error) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per user message send. Low frequency — user-initiated. |

### 1.7 `chat.message_queue_stale_drop`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/MessageQueueStore.swift:89-96` |
| **Emitter** | `recordQueueEventMetric(...)` → `MessageQueueStore.swift:132-141` |
| **Trigger** | `queueItemStarted(...)` called with a `queueVersion` older than the stored version. Indicates a stale queue notification from the server. |
| **Tags** | `source` ("queue_item_started"), `incoming_version`, `current_version` |
| **Threshold-gated** | No — emitted on every occurrence. Value always `1`. |
| **Volume** | Rare — only on race conditions between queue updates. |

### 1.8 `chat.message_queue_start_miss`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/MessageQueueStore.swift:108-115` |
| **Emitter** | `recordQueueEventMetric(...)` → `MessageQueueStore.swift:132-141` |
| **Trigger** | `queueItemStarted(...)` cannot find the matching item in its local queue (steering or follow-up). Server says item started but client never had it. |
| **Tags** | `kind` ("steer" or "followUp"), `queue_version` |
| **Threshold-gated** | No — emitted on every occurrence. Value always `1`. |
| **Volume** | Rare — only on queue desync. |

---

## 2. Session Lifecycle Metrics

### 2.1 `chat.ttft_ms` (Time to First Token)

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:575-579` |
| **Emitter** | `ChatSessionTelemetry.recordTTFT(...)` → `ChatSessionTelemetry.swift:65-71` |
| **Trigger** | Timer starts when a `turnAck` with `stage == .dispatched` for "prompt", "steer", or "follow_up" is received (line 562-566). Timer stops on the first TTFT-completion signal (text delta, thinking delta, tool use, etc.). Cleared on `.agentEnd`. |
| **Tags** | `provider`, `model` (extracted from session model string at turnAck time) |
| **Threshold-gated** | No — always emitted when both turnAck and completion signal arrive. |
| **Volume** | Once per agent turn (user sends message → first response token). |

### 2.2 `chat.catchup_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:755-756` |
| **Emitter** | `ChatSessionTelemetry.recordCatchup(...)` → `ChatSessionTelemetry.swift:91-93` |
| **Trigger** | After catch-up decision resolves: no gap, seq regression, ring miss, events applied, or events empty. |
| **Tags** | `result` ("no_gap", "seq_regression", "ring_miss", "applied", "empty", "fetch_failed") |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per reconnection catch-up attempt. |

### 2.3 `chat.catchup_ring_miss`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:833, 838` |
| **Emitter** | `ChatSessionTelemetry.recordCatchupRingMiss(...)` → `ChatSessionTelemetry.swift:97-99` |
| **Trigger** | After catch-up fetch returns: `missed=true` when server's ring buffer doesn't have the requested events (full reload needed), `missed=false` when events are available. |
| **Tags** | None |
| **Threshold-gated** | No. Value is `1` (missed) or `0` (not missed). |
| **Volume** | Once per catch-up fetch. |

### 2.4 `chat.fresh_content_lag_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:235-242` |
| **Emitter** | `ChatSessionTelemetry.recordFreshContentLag(...)` → `ChatSessionTelemetry.swift:73-85` |
| **Trigger** | Measures wall time from connect start to the first "fresh" data arrival. Recorded once per connect. Triggered by history load completion (various `reason` values). |
| **Tags** | `reason` ("history_applied", "history_replayed", "history_unchanged", "history_empty"), `cache` ("1"/"0"), `transport` |
| **Threshold-gated** | No — always emitted once per connect. |
| **Volume** | Once per session connection. |

### 2.5 `chat.cache_load_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:318-327` |
| **Emitter** | `ChatSessionTelemetry.recordCacheLoad(...)` → `ChatSessionTelemetry.swift:17-24` |
| **Trigger** | After loading cached timeline trace from `TimelineCache.shared`. Measures `loadTrace()` duration. |
| **Tags** | `hit` ("1"/"0"), `events` (cached event count) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per session connect (not on re-entry). |

### 2.6 `chat.reducer_load_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:344-351` (cache path), `:939-946` (history path) |
| **Emitter** | `ChatSessionTelemetry.recordReducerLoad(...)` → `ChatSessionTelemetry.swift:26-35` |
| **Trigger** | After `reducer.loadSession(events)` or `reducer.applyTraceWithLiveReplay(trace)` completes. Measures the state machine replay time. |
| **Tags** | `source` ("cache", "history", "history+replay"), `events` (trace event count), `items` (resulting timeline item count) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | 1-2 per session connect (once for cache, once for fresh history). |

### 2.7 `chat.full_reload_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift:970-975` |
| **Emitter** | `ChatSessionTelemetry.recordFullReload(...)` → `ChatSessionTelemetry.swift:101-110` |
| **Trigger** | After full session history fetch + trace replay + cache save. Measures entire `fetchAndLoadFullHistory(...)` duration. |
| **Tags** | `traceEvents` (event count) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per session connect or reconnect-with-reload. |

---

## 3. Session Usage Metrics (Batch)

All emitted from a single call site as a batch of 10 metrics.

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/ServerConnection+MessageRouter.swift:262-272` |
| **Emitter** | `emitSessionUsageMetricsIfNeeded(session)` → batch `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | On every session update from the server (session list refresh, session status change). Uses snapshot dedup — only emits when the computed `SessionUsageMetricSnapshot` differs from the last emitted one. |
| **Tags** | `provider`, `model` (parsed from session model string) |
| **Threshold-gated** | No, but **dedup-gated** — skips if snapshot is unchanged. |
| **Volume** | Once per unique session state change. Moderate frequency during active sessions (token counts update). |

### Metrics in the batch:

| Metric Name | Unit | Description |
|---|---|---|
| `chat.session_message_count` | count | Total messages in session |
| `chat.session_input_tokens` | count | Input tokens consumed |
| `chat.session_output_tokens` | count | Output tokens generated |
| `chat.session_total_tokens` | count | Total tokens (input + output) |
| `chat.session_mutating_tool_calls` | count | Tool calls that mutated files |
| `chat.session_files_changed` | count | Files changed by tools |
| `chat.session_added_lines` | count | Lines added |
| `chat.session_removed_lines` | count | Lines removed |
| `chat.session_context_tokens` | count | Current context window token usage |
| `chat.session_context_window` | count | Context window capacity |

---

## 4. Timeline Rendering Metrics

### 4.1 `chat.timeline_apply_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelinePerf.swift:250-260` |
| **Emitter** | `endCollectionApply(token)` → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | After `UICollectionViewDiffableDataSource.apply(snapshot)` completes. Timed with `DispatchTime.now().uptimeNanoseconds`. |
| **Tags** | `items` (total snapshot items), `changed` (items that changed in this apply) |
| **Threshold-gated** | **Yes — `durationMs >= 4`** (skips the 99% of applies that are 0-1ms). Also discards measurements ≥5000ms (suspension ceiling — background artifacts). |
| **Volume** | High during streaming — every coalescer flush triggers a snapshot apply (~30fps = ~30/sec). Filtered to ~1% of applies that exceed 4ms. |

### 4.2 `chat.timeline_layout_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelinePerf.swift:325-335` |
| **Emitter** | `endLayoutPass(token)` → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | After `UICollectionView.layoutIfNeeded()` completes. Timed with `DispatchTime.now().uptimeNanoseconds`. |
| **Tags** | `items` (total items in collection) |
| **Threshold-gated** | **Yes — `durationMs >= 2`** (skips trivial layouts). Also discards ≥5000ms suspension ceiling. |
| **Volume** | Same as apply — ~30/sec during streaming, filtered to non-trivial cases. |

### 4.3 `chat.cell_configure_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelinePerf.swift:382-396` |
| **Emitter** | `recordCellConfigure(rowType:durationMs:toolContext:)` → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | After a UICollectionView cell's `configure(...)` method completes. Called by cell registration closures. |
| **Tags** | `row_type` (e.g. "assistant_text", "tool_use", "user"). Optionally: `tool`, `expanded` ("1"/"0"), `content_type`, `output_bytes` (bucketed: "<1KB", "1-10KB", "10-50KB", "50-200KB", "200KB+") |
| **Threshold-gated** | **Yes — `durationMs >= 1`** (skips sub-millisecond configures to avoid Task.detached overhead exceeding measurement). |
| **Volume** | High during scrolling and streaming. Every visible cell configure ≥1ms is emitted. |

### 4.4 `chat.render_strategy_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelinePerf.swift:449-460` (render strategy), `:486-497` (tool row measurement) |
| **Emitter** | `recordRenderStrategy(...)` and `recordToolRowMeasurement(...)` → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | `recordRenderStrategy`: After a tool row's expanded content rendering completes (highlighting, ANSI parse, diff build). `recordToolRowMeasurement`: After a tool row size measurement completes. |
| **Tags** | `mode` (render mode, e.g. "syntax_highlight", "diff", "measurement.<name>"), `input_bytes` (bucketed), `language` (optional, for syntax highlighting) |
| **Threshold-gated** | `recordRenderStrategy`: **No** — always emitted. `recordToolRowMeasurement`: **Yes — `durationMs > 0`** (skips zero-cost measurements). |
| **Volume** | Per tool row render/measure. Moderate — only when tool output cells are configured or resized. |

### 4.5 `chat.timeline_hitch`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Collection/FrameBudgetMonitor.swift:112-120` |
| **Emitter** | `endSection()` → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | At end of a `FrameBudgetMonitor` section, **only if** hitches were detected (frame gaps >1.5× expected interval) OR worst frame exceeds hitch threshold. Value is `worstFrameMs`. |
| **Tags** | `section` (e.g. "tool_row_insert"), `hitch_count` |
| **Threshold-gated** | **Yes — only emitted when `hitchCount > 0` or `worstFrameMs > expectedIntervalMs × 1.5`**. |
| **Volume** | Low. Only during critical timeline operations (tool row inserts) that trigger hitch detection. |

---

## 5. Coalescer Metrics

### 5.1 `chat.coalescer_flush_events`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Runtime/DeltaCoalescer.swift:deliverBuffer()` |
| **Emitter** | `deliverBuffer()` accumulates into a ~1s window → `Task.detached` → `ChatMetricsService.shared.record(...)` |
| **Trigger** | Accumulated over ~30 flushes (~1 second at 33ms interval), then emitted as a single sample. Residual window drained on `flushNow()` (disconnect/session end). Value is total event count across the window. |
| **Tags** | `flushes` (number of flushes in the window — divide value by flushes for per-flush average) |
| **Threshold-gated** | Window-gated (~30 flushes before emit). |
| **Volume** | ~1/sec during streaming (was ~30/sec before windowing fix). |

### 5.2 `chat.coalescer_flush_bytes`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Runtime/DeltaCoalescer.swift:deliverBuffer()` |
| **Emitter** | Same window as above. |
| **Trigger** | Same window as above. Value is total estimated payload bytes across the window. |
| **Tags** | `flushes` (same as above) |
| **Threshold-gated** | Window-gated (~30 flushes before emit). |
| **Volume** | ~1/sec during streaming (was ~30/sec before windowing fix). |

---

## 6. Inbound Queue Metrics

### 6.1 `chat.inbound_queue_depth`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Networking/WebSocketClient.swift:566-572` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` in `Task.detached` |
| **Trigger** | On every inbound WS message, the per-session queue depth is checked. **Only emitted when the depth exceeds the previous high-water mark** for that session. |
| **Tags** | None (only `sessionId`) |
| **Threshold-gated** | **Yes — high-water-mark gated**. Only emits on new maximums, not every message. |
| **Volume** | Low-to-moderate. Resets per session. Emits only when queue grows to a new peak. |

---

## 7. Voice Metrics

All voice metrics route through `VoiceInputTelemetry.recordMetric(...)` or `VoiceInputTelemetry.recordCountMetric(...)`, which both dispatch to `ChatMetricsService.shared.record(...)` via `Task.detached(priority: .utility)`.

Common tags on all voice metrics: `engine` (e.g. "speech", "dictation", "remote"), `locale` (BCP-47), `source` (e.g. "composer", "unknown").

### 7.1 `chat.voice_prewarm_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputManager.swift:~248-272` |
| **Emitter** | `recordVoiceMetric(.voicePrewarmMs, ...)` via `VoiceInputTelemetry.recordMetric(...)` |
| **Trigger** | After `provider.prewarm(context:)` completes (success, cancellation, or error). Called from `prewarm(keyboardLanguage:source:)`. |
| **Tags** | `phase` ("prewarm"), `status` ("ok", "cancelled", "error"), `error` (on error — type name) |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per prewarm call (typically once per ChatView appearance). |

### 7.2 `chat.voice_setup_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputManager.swift:~370-400` (error/cancel paths), `:~365` (via `emitStartupTelemetry`) |
| **Emitter** | `recordVoiceMetric(.voiceSetupMs, ...)` via `VoiceInputTelemetry.recordMetric(...)` |
| **Trigger** | Emitted with **5 different phase tags** after `startRecording(...)` completes: `model_ready`, `transcriber_create`, `analyzer_start`, `audio_start`, `total`. Also emitted on error/cancel with `phase=total`. |
| **Tags** | `phase` ("model_ready", "transcriber_create", "analyzer_start", "audio_start", "total"), `status` ("ok", "cancelled", "error"), `path` ("warm_cache" or provider-specific), `error`/`error_kind` (on error). Plus provider-specific `setupMetricTags`. |
| **Threshold-gated** | No — always emitted. |
| **Volume** | 5 samples per successful recording start. 1 sample on error/cancel. Once per mic tap. |

### 7.3 `chat.voice_first_result_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputManager.swift:~322-330` |
| **Emitter** | `recordVoiceMetric(.voiceFirstResultMs, ...)` via `VoiceInputTelemetry.recordMetric(...)` |
| **Trigger** | Callback from `VoiceInputSessionMonitor.onFirstTranscript`. Measures time from recording start to first transcription result. |
| **Tags** | `phase` ("first_result"), `status` ("ok"), `result_type` (e.g. "volatile", "final") |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per recording session. |

### 7.4 `chat.voice_remote_probe_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputManager.swift:~423-433` |
| **Emitter** | `recordRemoteProbeMetric(probe, annotation:)` → `VoiceInputTelemetry.recordMetric(.voiceRemoteProbeMs, ...)` |
| **Trigger** | After probing remote ASR endpoint reachability. Called during `effectiveEngine(...)` resolution and during `prewarm`/`startRecording` when remote mode is active. |
| **Tags** | `status` ("ok" or "error"), `cached` ("1"/"0"), `reachable` ("1"/"0"), `host` |
| **Threshold-gated** | No — always emitted. |
| **Volume** | Once per engine resolution when remote is considered. |

### 7.5 `chat.voice_remote_chunk_upload_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputTelemetry.swift:~93-101` |
| **Emitter** | `VoiceInputTelemetry.recordRemoteChunkTelemetry(chunk, annotation:)` → `VoiceInputTelemetry.recordMetric(.voiceRemoteChunkUploadMs, ...)` |
| **Trigger** | After each audio chunk upload to remote ASR completes. Only emitted when `chunk.uploadDurationMs` is non-nil. |
| **Tags** | `chunk_status`, `chunk_final` ("1"/"0"), `error_category` (optional). Plus all common voice tags. |
| **Threshold-gated** | **Yes — only emitted when `uploadDurationMs != nil`** (i.e., upload actually occurred). |
| **Volume** | Per remote chunk upload during recording. Moderate — depends on chunk interval. |

### 7.6 `chat.voice_remote_chunk_audio_ms`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputTelemetry.swift:~81-89` |
| **Emitter** | `VoiceInputTelemetry.recordRemoteChunkTelemetry(chunk, annotation:)` → `VoiceInputTelemetry.recordMetric(.voiceRemoteChunkAudioMs, ...)` |
| **Trigger** | On every remote chunk telemetry event. Value is the audio duration in ms of the chunk. |
| **Tags** | `chunk_status`, `chunk_final`, `error_category` (optional) |
| **Threshold-gated** | No — always emitted for each chunk. |
| **Volume** | Per remote chunk during recording. |

### 7.7 `chat.voice_remote_chunk_bytes`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputTelemetry.swift:~91-98` |
| **Emitter** | `VoiceInputTelemetry.recordRemoteChunkTelemetry(chunk, annotation:)` → `VoiceInputTelemetry.recordCountMetric(.voiceRemoteChunkBytes, ...)` |
| **Trigger** | On remote chunk telemetry, **only when `chunk.wavBytes > 0`**. Value is the WAV byte count. |
| **Tags** | `chunk_status`, `chunk_final`, `error_category` (optional) |
| **Threshold-gated** | **Yes — `wavBytes > 0`**. |
| **Volume** | Per remote chunk during recording. |

### 7.8 `chat.voice_remote_chunk_chars`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputTelemetry.swift:~103-109` |
| **Emitter** | `VoiceInputTelemetry.recordRemoteChunkTelemetry(chunk, annotation:)` → `VoiceInputTelemetry.recordCountMetric(.voiceRemoteChunkChars, ...)` |
| **Trigger** | On remote chunk telemetry, **only when `chunk.textLength > 0`**. Value is the character count of the transcribed text. |
| **Tags** | `chunk_status`, `chunk_final`, `error_category` (optional) |
| **Threshold-gated** | **Yes — `textLength > 0`**. |
| **Volume** | Per chunk that produces text output. |

### 7.9 `chat.voice_remote_chunk_error`

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Core/Services/VoiceInputTelemetry.swift:~111-118` |
| **Emitter** | `VoiceInputTelemetry.recordRemoteChunkTelemetry(chunk, annotation:)` → `VoiceInputTelemetry.recordCountMetric(.voiceRemoteChunkError, ...)` |
| **Trigger** | **Only when `chunk.status == .error`**. Value is always `1`. |
| **Tags** | `chunk_status` ("error"), `chunk_final`, `error_category` |
| **Threshold-gated** | **Yes — only on error status**. |
| **Volume** | Rare — only on chunk-level errors. |

---

## 8. Plot Telemetry

All emitted from a single function: `emitPlotTelemetryIfNeeded(snapshot:)` in `NativeExpandedToolViews.swift`. Uses **signature dedup** — only emits when the combined hash of (telemetry snapshot + mark count + row count) changes. Not emitted for full-screen plots (only inline).

| Field | Value |
|---|---|
| **File** | `ios/Oppi/Features/Chat/Timeline/Tool/NativeExpandedToolViews.swift:496-520` |
| **Emitter** | Direct `ChatMetricsService.shared.record(...)` (not detached — runs in SwiftUI `.task(id:)`) |
| **Trigger** | SwiftUI `.task(id: telemetrySnapshot)` on the chart's `GeometryReader`. Fires when the telemetry snapshot identity changes (viewport resize, spec change). |

### 8.1 `plot.axis_visible_tick_count`

| **Tags** | None |
| **Threshold-gated** | No (dedup only). |
| **Volume** | Once per unique plot render. Low. |

### 8.2 `plot.legend_item_count`

| **Tags** | None |
| **Threshold-gated** | No (dedup only). |
| **Volume** | Once per unique plot render. Low. |

### 8.3 `plot.scroll_enabled`

| **Tags** | None |
| **Threshold-gated** | No (dedup only). Value: `1` (enabled) or `0` (disabled). |
| **Volume** | Once per unique plot render. Low. |

### 8.4 `plot.auto_adjustments`

| **Tags** | None |
| **Threshold-gated** | No (dedup only). |
| **Volume** | Once per unique plot render. Low. |

---

## Summary Table

| # | Metric | File | Gate | Volume | Unit |
|---|---|---|---|---|---|
| 1 | `chat.ws_connect_ms` | ChatSessionManager.swift:472 | None | 1/connection | ms |
| 2 | `chat.stream_open_ms` | SessionStreamCoordinator.swift:140 | None | 1/subscription | ms |
| 3 | `chat.subscribe_ack_ms` | SessionStreamCoordinator.swift:196 | None | 1/subscription | ms |
| 4 | `chat.connected_dispatch_ms` | ChatSessionManager.swift:450 | None | 1/connection | ms |
| 5 | `chat.queue_sync_ms` | SessionStreamCoordinator.swift:555 | None | 1-2/connection | ms |
| 6 | `chat.message_queue_ack_ms` | MessageSender.swift:429 | None | 1/user message | ms |
| 7 | `chat.message_queue_stale_drop` | MessageQueueStore.swift:89 | None (event-driven) | Rare | count |
| 8 | `chat.message_queue_start_miss` | MessageQueueStore.swift:108 | None (event-driven) | Rare | count |
| 9 | `chat.ttft_ms` | ChatSessionManager.swift:575 | None | 1/agent turn | ms |
| 10 | `chat.catchup_ms` | ChatSessionManager.swift:755 | None | 1/reconnect | ms |
| 11 | `chat.catchup_ring_miss` | ChatSessionManager.swift:833,838 | None | 1/catch-up fetch | count |
| 12 | `chat.fresh_content_lag_ms` | ChatSessionManager.swift:235 | None | 1/connect | ms |
| 13 | `chat.cache_load_ms` | ChatSessionManager.swift:318 | None | 1/connect | ms |
| 14 | `chat.reducer_load_ms` | ChatSessionManager.swift:344,939 | None | 1-2/connect | ms |
| 15 | `chat.full_reload_ms` | ChatSessionManager.swift:970 | None | 1/connect | ms |
| 16 | `chat.session_message_count` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 17 | `chat.session_input_tokens` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 18 | `chat.session_output_tokens` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 19 | `chat.session_total_tokens` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 20 | `chat.session_mutating_tool_calls` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 21 | `chat.session_files_changed` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 22 | `chat.session_added_lines` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 23 | `chat.session_removed_lines` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 24 | `chat.session_context_tokens` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 25 | `chat.session_context_window` | ServerConnection+MessageRouter.swift:262 | Dedup (snapshot) | Per session update | count |
| 26 | `chat.timeline_apply_ms` | ChatTimelinePerf.swift:255 | **≥4ms** + <5000ms | ~30/sec (filtered) | ms |
| 27 | `chat.timeline_layout_ms` | ChatTimelinePerf.swift:330 | **≥2ms** + <5000ms | ~30/sec (filtered) | ms |
| 28 | `chat.cell_configure_ms` | ChatTimelinePerf.swift:387 | **≥1ms** | Per visible cell | ms |
| 29 | `chat.render_strategy_ms` | ChatTimelinePerf.swift:454,491 | None / **>0ms** | Per tool row render | ms |
| 30 | `chat.timeline_hitch` | FrameBudgetMonitor.swift:112 | **hitchCount>0** | Per critical section | ms |
| 31 | `chat.coalescer_flush_events` | DeltaCoalescer.swift | ~30-flush window | ~1/sec streaming | count |
| 32 | `chat.coalescer_flush_bytes` | DeltaCoalescer.swift | ~30-flush window | ~1/sec streaming | count |
| 33 | `chat.inbound_queue_depth` | WebSocketClient.swift:566 | **High-water only** | Per new peak | count |
| 34 | `chat.voice_prewarm_ms` | VoiceInputManager.swift:~252 | None | 1/prewarm | ms |
| 35 | `chat.voice_setup_ms` | VoiceInputManager.swift:~365 | None | 5/recording start | ms |
| 36 | `chat.voice_first_result_ms` | VoiceInputManager.swift:~322 | None | 1/recording | ms |
| 37 | `chat.voice_remote_probe_ms` | VoiceInputManager.swift:~423 | None | 1/engine resolve | ms |
| 38 | `chat.voice_remote_chunk_upload_ms` | VoiceInputTelemetry.swift:~93 | Non-nil duration | Per chunk | ms |
| 39 | `chat.voice_remote_chunk_audio_ms` | VoiceInputTelemetry.swift:~81 | None | Per chunk | ms |
| 40 | `chat.voice_remote_chunk_bytes` | VoiceInputTelemetry.swift:~91 | **>0 bytes** | Per chunk | count |
| 41 | `chat.voice_remote_chunk_chars` | VoiceInputTelemetry.swift:~103 | **>0 chars** | Per chunk | count |
| 42 | `chat.voice_remote_chunk_error` | VoiceInputTelemetry.swift:~111 | **Error status only** | Rare | count |
| 43 | `plot.axis_visible_tick_count` | NativeExpandedToolViews.swift:496 | Dedup (signature) | 1/unique plot | count |
| 44 | `plot.legend_item_count` | NativeExpandedToolViews.swift:502 | Dedup (signature) | 1/unique plot | count |
| 45 | `plot.scroll_enabled` | NativeExpandedToolViews.swift:508 | Dedup (signature) | 1/unique plot | ratio |
| 46 | `plot.auto_adjustments` | NativeExpandedToolViews.swift:514 | Dedup (signature) | 1/unique plot | count |

---

## Volume Tiers

**Moderate volume (~1/sec during streaming, windowed):**
- `chat.coalescer_flush_events` — accumulated over ~30 flushes (~1s window)
- `chat.coalescer_flush_bytes` — accumulated over ~30 flushes (~1s window)

**Medium volume (per-frame, but threshold-filtered):**
- `chat.timeline_apply_ms` — ≥4ms gate drops ~99% of samples
- `chat.timeline_layout_ms` — ≥2ms gate drops most samples
- `chat.cell_configure_ms` — ≥1ms gate, but many cells exceed 1ms during scroll

**Low volume (once per session/connection/turn):**
- All connection metrics (ws_connect, stream_open, subscribe_ack, etc.)
- TTFT, catchup, fresh_content_lag, cache_load, reducer_load, full_reload
- Session usage batch (dedup-gated)
- Voice metrics
- Plot metrics (dedup-gated)

**Rare/conditional:**
- `chat.message_queue_stale_drop`, `chat.message_queue_start_miss` — queue desync only
- `chat.timeline_hitch` — hitches only
- `chat.voice_remote_chunk_error` — errors only
- `chat.inbound_queue_depth` — new peak only

---

## Defined but Never Emitted

Cross-referencing `ChatMetricName` enum cases against actual emission sites:

All 46 enum cases in `MetricKitModels.swift` have corresponding emission sites. **No orphaned metric names.**

Note: `wsDecodeMs` was previously defined but was explicitly removed (comment in `MetricKitModels.swift`: "Removed: wsDecodeMs — high-volume noise (32% of samples, almost always 0ms)").
