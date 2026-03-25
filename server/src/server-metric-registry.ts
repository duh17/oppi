/**
 * Server operational metric registry.
 *
 * Single source-of-truth for every server-side metric. Mirrors the iOS
 * CHAT_METRIC_REGISTRY pattern: define here first, then instrument.
 *
 * All metrics (P0–P2) are defined in the registry type for forward
 * compatibility. Only P0 (network/relay validation) is instrumented
 * in Phase 1.
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
  "server.ws_messages_received": {
    unit: "count",
    description: "Messages received over a single WebSocket connection lifetime.",
  },
  "server.ws_close_code": {
    unit: "count",
    description: "WebSocket close code (1000=normal, 1006=abnormal, etc). Tagged by code.",
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
    description: "Peak concurrent active sessions observed in the sampling interval.",
  },

  // ── P1: Turn / LLM Performance ──
  "server.turn_duration_ms": {
    unit: "ms",
    description: "Agent turn duration (agent_start to agent_end).",
  },
  "server.turn_ttft_ms": {
    unit: "ms",
    description: "Server-side time-to-first-token (agent_start to first text_delta).",
  },
  "server.turn_input_tokens": {
    unit: "count",
    description: "Input tokens consumed in a single turn (from message_end usage).",
  },
  "server.turn_output_tokens": {
    unit: "count",
    description: "Output tokens produced in a single turn (from message_end usage).",
  },
  "server.turn_cost": {
    unit: "count",
    description: "Turn cost in microdollars (usage.cost * 1_000_000, integer).",
  },
  "server.turn_tool_calls": {
    unit: "count",
    description: "Tool calls executed in a single turn.",
  },
  "server.turn_error": {
    unit: "count",
    description: "Turns that ended with an error. Tagged by error category.",
  },

  // ── P1: Permission Gate ──
  "server.gate_check_ms": {
    unit: "ms",
    description: "Gate policy evaluation latency (checkToolCall -> decision).",
  },
  "server.gate_decision": {
    unit: "count",
    description: "Gate decisions. Tagged by action (allow, deny, ask).",
  },
  "server.gate_approval_wait_ms": {
    unit: "ms",
    description: "Time user took to respond to a permission request (ask -> resolve).",
  },
  "server.gate_timeout": {
    unit: "count",
    description: "Permission requests that timed out waiting for user response.",
  },

  // ── P2: Capacity / Throughput ──
  "server.http_request_ms": {
    unit: "ms",
    description: "HTTP request duration. Tagged by method, path_pattern, status_code.",
  },
  "server.event_ring_utilization": {
    unit: "ratio",
    description: "Event ring fill ratio (len/capacity). Tagged by ring (session, user_stream).",
  },
  "server.catchup_events": {
    unit: "count",
    description: "Events replayed during catch-up. Tagged by ring (session, user_stream).",
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
    description: "Subscriber count at time of broadcast. Sampled on durable messages only.",
  },

  // ── P2: Error Tracking ──
  "server.auto_retry": {
    unit: "count",
    description: "Auto-retry events. Tagged by attempt number.",
  },
  "server.compaction_ms": {
    unit: "ms",
    description: "Auto-compaction duration.",
  },
  "server.compaction_result": {
    unit: "count",
    description: "Compaction outcomes. Tagged by result (success, aborted, will_retry).",
  },
  // ── Session Auto-Title ──
  "server.session_title_gen_ms": {
    unit: "ms",
    description:
      "Auto-title generation duration. Tagged by model, status (success/error/timeout), tokens.",
  },
} as const satisfies Readonly<Record<string, ServerMetricDefinition>>;

export type ServerMetricName = keyof typeof SERVER_METRIC_REGISTRY;
