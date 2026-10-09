/**
 * Server operational metric registry.
 *
 * Define a metric here before emitting it. Retired names stay so archived
 * dashboard imports still recognize them; they are not emitted.
 */

export type ServerMetricUnit = "ms" | "count" | "bytes" | "ratio";

export interface ServerMetricDefinition {
  unit: ServerMetricUnit;
  description: string;
}

export const SERVER_METRIC_REGISTRY = {
  // ── P0: Network / Relay Validation ──
  "server.ws_handshake_ms": {
    unit: "ms",
    description: "Server-side WebSocket upgrade duration (upgrade request to open).",
  },
  "server.ws_first_message_ms": {
    unit: "ms",
    description: "Time from WS open to first client message received.",
  },
  "server.ws_ping_rtt_ms": {
    unit: "ms",
    description: "Server-initiated ping to pong round-trip time.",
  },
  "server.ws_session_duration_ms": {
    unit: "ms",
    description: "Total WebSocket connection lifetime (open to close).",
  },
  "server.ws_messages_sent": {
    unit: "count",
    description: "Messages sent over a single WebSocket connection lifetime.",
  },
  "server.ws_message_sent": {
    unit: "count",
    description:
      "Per-message WebSocket sends. Tagged by type, subscription level, and stream path.",
  },
  "server.ws_message_received": {
    unit: "count",
    description: "Per-message WebSocket receives. Tagged by type and stream path.",
  },
  "server.ws_binary_received_bytes": {
    unit: "bytes",
    description: "Binary WebSocket payload bytes received. Tagged by stream path.",
  },
  "server.ws_messages_received": {
    unit: "count",
    description: "Messages received over a single WebSocket connection lifetime.",
  },
  "server.ws_close_code": {
    unit: "count",
    description:
      "WebSocket close code (1000=normal, 1006=abnormal, etc). Tagged by code and stream path.",
  },
  "server.ws_ping_timeout": {
    unit: "count",
    description: "Ping timeout terminations (dead connections detected).",
  },

  // ── P1: Session Lifecycle ──
  "server.session_create_ms": {
    unit: "ms",
    description: "Total SdkBackend.create() duration (model resolve + SDK init + extension bind).",
  },
  "server.session_create_sdk_ms": {
    unit: "ms",
    description: "SDK session setup portion of session creation (before extension bind).",
  },
  "server.session_create_bind_ms": {
    unit: "ms",
    description: "Extension bind portion of session creation.",
  },
  "server.session_subscribe_ms": {
    unit: "ms",
    description: "Full subscribe flow duration (startSession + connected + state + catchUp).",
  },
  "server.session_end": {
    unit: "count",
    description: "Session ended. Tagged by reason (completed, stopped, error, idle_timeout).",
  },
  "server.session_active_peak": {
    unit: "count",
    description:
      "Retired. Not emitted. Peak concurrent sessions are sessions.peak on the server resource sample. Kept for archived dashboard import.",
  },

  // ── P1: Agent workload / responsiveness ──
  "server.turn_duration_ms": {
    unit: "ms",
    description:
      "Full agent work duration (agent_start to agent_end). Tagged by runtime (oppi, durable, or pi-tui), the exact session-configured provider/model route, and bounded configured thinking when known. Workload telemetry, not accepted-task correctness.",
  },
  "server.turn_ttft_ms": {
    unit: "ms",
    description:
      "Server-side time-to-first-token (agent_start to first text_delta or thinking_delta). Tagged by runtime (oppi, durable, or pi-tui), the exact session-configured provider/model route, and bounded configured thinking when known.",
  },
  "server.turn_input_tokens": {
    unit: "count",
    description:
      "Input tokens consumed by turns (from message_end usage). Tagged by runtime (oppi, durable, or pi-tui) and the exact session-configured provider/model route when known. Aggregated by sum before storage.",
  },
  "server.turn_output_tokens": {
    unit: "count",
    description:
      "Output tokens produced by turns (from message_end usage). Tagged by runtime (oppi, durable, or pi-tui) and the exact session-configured provider/model route when known. Aggregated by sum before storage.",
  },
  "server.turn_cost": {
    unit: "count",
    description:
      "Turn cost in microdollars (usage.cost * 1_000_000, integer). Tagged by runtime (oppi, durable, or pi-tui) and the exact session-configured provider/model route when known. Aggregated by sum before storage.",
  },
  "server.turn_tool_calls": {
    unit: "count",
    description:
      "Tool calls executed in a single turn. Tagged by runtime (oppi, durable, or pi-tui) and the exact session-configured provider/model route when known. Workload telemetry, not accepted-task correctness.",
  },
  "server.turn_error": {
    unit: "count",
    description:
      "Turns that ended with an error. Tagged by runtime (oppi, durable, or pi-tui), a bounded error category, and the exact session-configured provider/model route and configured thinking when known. Operational, not accepted-task correctness.",
  },
  "server.tool_duration_ms": {
    unit: "ms",
    description:
      "Paired tool-call wall time (tool_execution_start to matching tool_execution_end). Tagged by runtime (oppi, durable, or pi-tui), the exact session-configured provider/model route, tool, and status. Omitted when start or end is missing.",
  },
  "server.tool_result": {
    unit: "count",
    description:
      "One sample per observed tool_execution_end. Tagged by runtime (oppi, durable, or pi-tui), the exact session-configured provider/model route, sanitized tool name, and status. Operational success is not accepted-task correctness.",
  },

  // ── P2: Capacity / Throughput ──
  "server.http_request_ms": {
    unit: "ms",
    description:
      "HTTP request duration. Tagged by method, path_pattern, status_code. Fast successful routine/navigation routes are threshold-gated. server.http_response_bytes uses the same decision and tags.",
  },
  "server.http_response_bytes": {
    unit: "bytes",
    description:
      "HTTP response body bytes actually written. Same tags and gating decision as server.http_request_ms. Omitted for WebSocket upgrades, HTTP 101, and unmeasurable chunks.",
  },
  "server.mcp_connect_ms": {
    unit: "ms",
    description:
      "First MCP server connect on a durable session. Tagged by sessionId, status (connected, failed, error), and reason (auth, connect, config) when not connected. Config errors record 0. Server names and error text are omitted.",
  },
  "server.schedule_run_ms": {
    unit: "ms",
    description:
      "Schedule dispatch duration. Tagged by status (completed, failed), kind (due, manual), and a bounded reason on failure. Not the HTTP request that started a manual run.",
  },
  "server.event_ring_utilization": {
    unit: "ratio",
    description:
      "Event ring fill ratio (len/capacity). Tagged by ring. Aggregated by max before storage.",
  },
  "server.catchup_events": {
    unit: "count",
    description: "Events replayed during catch-up. Tagged by ring.",
  },
  "server.catchup_miss": {
    unit: "count",
    description: "Catch-up requests that couldn't be served from the ring (full reload needed).",
  },
  "server.push_send_ms": {
    unit: "ms",
    description: "APNs push send latency. Tagged by push_type.",
  },
  "server.push_result": {
    unit: "count",
    description: "Push send results. Tagged by push_type, success (true/false).",
  },
  "server.broadcast_fanout": {
    unit: "count",
    description:
      "Subscriber count at time of durable broadcasts. Tagged by type. Aggregated by max before storage.",
  },

  // ── P2: Error Tracking ──
  "server.auto_retry": {
    unit: "count",
    description:
      "Auto-retry events. Tagged by runtime (oppi, durable, or pi-tui) and attempt number.",
  },
  "server.compaction_ms": {
    unit: "ms",
    description: "Auto-compaction duration. Tagged by runtime (oppi, durable, or pi-tui).",
  },
  "server.compaction_result": {
    unit: "count",
    description:
      "Compaction outcomes. Tagged by runtime (oppi, durable, or pi-tui) and result (success, failed, aborted, will_retry).",
  },
  // ── Session Auto-Title ──
  "server.session_title_gen_ms": {
    unit: "ms",
    description:
      "Auto-title generation duration. Tagged by model, status (success/error/timeout), tokens.",
  },

  // ── Ask Extension ──
  "server.ask_round_trip_ms": {
    unit: "ms",
    description:
      "Ask extension round-trip: direct ask UI request to user answer resolution. Tagged by cancelled, questionCount.",
  },

  // ── Dictation Pipeline ──
  "server.dictation_session_ms": {
    unit: "ms",
    description:
      "Full dictation session duration (dictation_start to dictation_final sent). Tagged by language.",
  },
  "server.dictation_audio_duration_ms": {
    unit: "ms",
    description: "Audio duration of the dictation session in ms. Tagged by language.",
  },
  "server.dictation_first_audio_ms": {
    unit: "ms",
    description: "Time from dictation_start to first audio frame received by the server.",
  },
  "server.dictation_first_result_ms": {
    unit: "ms",
    description: "Time from dictation_start to first visible streaming transcript update.",
  },
  "server.dictation_first_result_audio_ms": {
    unit: "ms",
    description: "Audio duration received when the first visible transcript update arrived.",
  },
  "server.dictation_result_updates": {
    unit: "count",
    description: "Visible streaming transcript updates forwarded before the final transcript.",
  },
  "server.dictation_stt_ms": {
    unit: "ms",
    description: "Final STT latency on session stop. Tagged by phase (finalize), audio_seconds.",
  },
  "server.dictation_stt_audio_ratio": {
    unit: "ratio",
    description:
      "Real-time factor: STT latency / audio duration. <1.0 means faster than real-time. Tagged by phase.",
  },
  "server.dictation_retranscribe_ms": {
    unit: "ms",
    description: "Retired. Not emitted. Kept for archived dashboard import.",
  },
  "server.dictation_finalize_ms": {
    unit: "ms",
    description: "Total finalize duration (final STT + response emit). Tagged by language.",
  },
  "server.dictation_retranscribe_count": {
    unit: "count",
    description: "Retired. Not emitted. Kept for archived dashboard import.",
  },
  "server.dictation_retranscribe_skip": {
    unit: "count",
    description: "Retired. Not emitted. Kept for archived dashboard import.",
  },
  "server.dictation_error": {
    unit: "count",
    description: "Dictation errors. Tagged by phase (stt), fatal (true/false).",
  },
} as const satisfies Readonly<Record<string, ServerMetricDefinition>>;

export type ServerMetricName = keyof typeof SERVER_METRIC_REGISTRY;
