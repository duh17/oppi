/**
 * Telemetry catalog: the single declaration of every telemetry event Oppi
 * records. Pure data plus types; no runtime imports.
 *
 * Every consumer derives from this file or is checked against it:
 * - server ingest (`POST /telemetry/events`) validates app events against it,
 * - server emitters get compile-time types from it (`ServerTelemetry.record`),
 * - the server collector reads `storage` to aggregate before writing,
 * - `scripts/generate-telemetry-catalog.ts` writes the Swift event structs,
 * - `scripts/telemetry-review.ts` reads groups, units, and SLOs,
 * - `scripts/check-telemetry.ts` enforces the invariants below in `npm run check`.
 *
 * Rules (enforced by check-telemetry):
 * - Event names are `<origin>.<snake_case>`; origin `app` (Apple client) or `server`.
 * - Field names are snake_case and end with their unit suffix (`_ms`, `_bytes`,
 *   `_mb`, `_pct`, `_ratio`, `_usd_micros`); `count` and `bool` fields have none.
 * - Tag keys are snake_case and have exactly one meaning, declared once in
 *   `TAGS`. Numbers are never tags (counts and sizes are fields); IDs are never
 *   tags (`sessionId`/`workspaceId` are record fields).
 * - An event may narrow an enum tag to a subset of its vocabulary.
 * - Removed events are deleted, not retired.
 */

export type TelemetryOrigin = "app" | "server";

/**
 * `pct` is 0–100 (may exceed 100 for multi-core CPU), `ratio` is 0–1,
 * `bool` is 0 or 1, `usd_micros` is integer millionths of a US dollar.
 */
export type FieldUnit = "ms" | "count" | "bytes" | "mb" | "pct" | "ratio" | "usd_micros" | "bool";

export interface FieldSpec {
  readonly unit: FieldUnit;
  /** Absent on some occurrences of the event (for example a phase that never ran). */
  readonly optional?: true;
}

export type FieldDef = FieldUnit | FieldSpec;

export interface BucketEdge {
  readonly name: string;
  /** Exclusive upper bound of the measured value; the last bucket has none. */
  readonly below?: number;
}

/**
 * - `enum`: closed value set; events may narrow it.
 * - `bucket`: a number mapped to a named bucket; both sides share the edges.
 * - `name`: open but bounded identifier matching `NAME_TAG_PATTERN` that does
 *   not look like a host, URL, or path (`looksLikeLocation`); anything else is
 *   stored as `unknown`. `route` lets a value start with `/` (a normalized
 *   route template such as `/workspaces/:workspaceId`); no other key may.
 */
export type TagDef =
  | { readonly kind: "enum"; readonly values: readonly string[]; readonly description: string }
  | {
      readonly kind: "bucket";
      readonly source: FieldUnit;
      readonly buckets: readonly BucketEdge[];
      readonly description: string;
    }
  | { readonly kind: "name"; readonly description: string; readonly route?: true };

/**
 * Characters a `name` tag value may use besides ASCII letters and digits.
 * `:` and `@` keep HTTP route patterns (`/workspaces/:workspaceId`) and
 * versioned model ids (`claude-opus-4@20250514`, `qwen3:32b`). `-` stays last
 * so the string drops into a regex character class as is.
 */
export const NAME_TAG_PUNCTUATION = "._/:@-";
export const NAME_TAG_MAX_LENGTH = 128;
export const NAME_TAG_PATTERN = new RegExp(
  `^[A-Za-z0-9${NAME_TAG_PUNCTUATION}]{1,${NAME_TAG_MAX_LENGTH}}$`,
);
export const NAME_TAG_FALLBACK = "unknown";

export interface TagUse {
  readonly required?: true;
  /** Narrowed subset of an enum tag's vocabulary. */
  readonly values?: readonly string[];
}

/**
 * Drop the event when `field` is present and outside `[min, max)`. A rule with
 * `where` applies only when every listed tag has one of the listed values.
 * Applied by the emitter (Swift generated code, server emitters) and again at
 * ingest.
 */
export interface EmitRule {
  readonly field: string;
  readonly min?: number;
  readonly max?: number;
  readonly where?: Readonly<Record<string, readonly string[]>>;
}

export type AggregateOp = "sum" | "max";

/**
 * Server only. `aggregate` folds every event with the same tag set, session,
 * and workspace in one collector flush window (60 s) into one record, combining
 * each field with its op. Without `storage`, every event is one record.
 */
export interface StorageSpec {
  readonly aggregate: Readonly<Record<string, AggregateOp>>;
}

export interface SloSpec {
  readonly field: string;
  /** Threshold for the trimmed mean of the lowest 99% of values. */
  readonly tm99: number;
  readonly label: string;
  /** Pass when the value is at or above the threshold. */
  readonly lowerIsBad?: true;
  /** Only events whose tags match count toward the SLO series. */
  readonly where?: Readonly<Record<string, readonly string[]>>;
}

export interface EventDef {
  /** The question this event answers. */
  readonly description: string;
  readonly group: GroupKey;
  readonly fields: Readonly<Record<string, FieldDef>>;
  readonly tags?: Readonly<Record<string, TagUse>>;
  readonly emit?: readonly EmitRule[];
  readonly storage?: StorageSpec;
  readonly slo?: readonly SloSpec[];
}

// ── Review and dashboard groups ──

export const GROUPS = {
  ux: {
    label: "UX Responsiveness",
    note: "User-visible wait time. Do not put full agent work duration in this group.",
  },
  connection: {
    label: "Connection Reliability",
    note: "Command/session readiness and stream health. These are user-blocking when they fail or tail out.",
  },
  rendering: {
    label: "Rendering Smoothness",
    note: "Frame-budget work on the 120 Hz budget (8.3 ms).",
  },
  media: {
    label: "Attention and Media UX",
    note: "Human-in-the-loop, sharing, and media playback. Ask response is user dwell time, not app latency.",
  },
  dictation_ux: {
    label: "Dictation UX",
    note: "Client dictation and voice input as the user experiences it.",
  },
  dictation_backend: {
    label: "Dictation Backend",
    note: "Server speech-to-text and finalize work.",
  },
  session_list: {
    label: "Session List",
    note: "Session list compute and SwiftUI body churn.",
  },
  device: {
    label: "Device",
    note: "Client CPU, memory, thermal pressure, and main-thread stalls.",
  },
  server: {
    label: "Server",
    note: "Resource pressure. event_loop_p99_ms is the ungated trend; the release gate uses event_loop_max_ms.",
  },
  workload: {
    label: "Agent Workload",
    note: "Long values usually mean the agent was working. Call them bad only when correlated with no progress, high TTFT, tool hangs, errors, or missing UI updates. Operational success is not accepted-task correctness.",
  },
  server_ops: {
    label: "Server Operations",
    note: "HTTP routes, WebSocket plumbing, push, MCP, schedules, and session lifecycle drill-down.",
  },
} as const satisfies Readonly<Record<string, { label: string; note: string }>>;

export type GroupKey = keyof typeof GROUPS;

// ── Tag vocabulary ──

const SIZE_BUCKETS = [
  { name: "under_1kb", below: 1_000 },
  { name: "under_10kb", below: 10_000 },
  { name: "under_50kb", below: 50_000 },
  { name: "under_200kb", below: 200_000 },
  { name: "over_200kb" },
] as const satisfies readonly BucketEdge[];

const TAGS = {
  status: {
    kind: "enum",
    values: ["ok", "error", "cancelled", "timeout"],
    description:
      "Mechanical outcome of the measured operation. Success is always `ok`; failure `error`.",
  },
  result: {
    kind: "enum",
    values: [
      // app.catchup
      "missing_epoch_baseline",
      "missing_epoch",
      "seq_regression",
      "epoch_baseline",
      "epoch_changed",
      "no_gap",
      "fetch_failed",
      "not_live",
      "epoch_mismatch",
      "ring_miss",
      "applied",
      // app.ws_wait
      "already_connected",
      "connected",
      "timeout",
      // server.compaction
      "will_retry",
      // server.push
      "delivered",
      "gone",
      "rejected",
      "unavailable",
      "failed",
      "throttled",
      "no_activity",
      // app.ask_response
      "answered",
      "empty",
      "ignored",
      // server.catchup
      "replayed",
      "miss",
      // server.dictation_finalize
      "transcribed",
      "no_audio",
    ],
    description: "Event-specific domain outcome; each event narrows it.",
  },
  reason: {
    kind: "enum",
    values: [
      // app.fresh_content_lag
      "cache_hit",
      "conversation_stream",
      "reconnect_conversation_stream",
      "reconnect_no_gap",
      "reconnect_applied",
      "reconnect_full_reload_scheduled",
      "stream_seq",
      "history_empty",
      "history_applied_empty",
      "history_deferred_to_live",
      "history_unchanged",
      "history_applied",
      "history_replayed",
      "history_first_message_fallback",
      // app.app_event_stream_reconnect
      "receive_error",
      "handshake_http",
      "protocol_close",
      "recoverable_receive",
      "ping_watchdog",
      "auth_current_token",
      "auth_refresh",
      // server.session_end
      "completed",
      "stopped",
      "error",
      "idle_timeout",
      "server_restart",
      "store_failed",
      // server.schedule_run
      "lease_lost",
      "not_found",
      "launch_in_progress",
      // server.dictation_stream_error
      "dictation_unavailable",
      "unsupported_message",
      "other",
    ],
    description: "Why the event happened; each event narrows it.",
  },
  error_kind: {
    kind: "enum",
    values: [
      "network",
      "timeout",
      "decode",
      "cancelled",
      "not_connected",
      "no_connection",
      "no_workspace",
      "agent_launch_failed",
      "request_failed",
      "prompt_delivery",
      "http_status",
      "url_error",
      "misconfigured",
      "capture_buffer_overflow",
      "bluetooth_route_lost",
      "capture_pipeline_dead",
      "unsupported_mime",
      "remote_error",
      "invalid_format",
      "oversized_chunk",
      "avfoundation",
      "stt",
      "request_too_large",
      "overloaded",
      "rate_limit",
      "auth",
      "connect",
      "config",
      "json_parse",
      "terminated",
      "other",
    ],
    description:
      "Coarse error class, one vocabulary for every event. Never a platform type name, error text, or code.",
  },
  phase: {
    kind: "enum",
    values: [
      "initial",
      "refresh",
      "deferred",
      "start",
      "load",
      "stream",
      "activate",
      "chunk",
      "source",
      "player_item",
      "player_state",
      "stall",
      "call_start",
      "call_end",
      "dictation_start",
    ],
    description: "Step of the operation in which the event happened; each event narrows it.",
  },
  transport: {
    kind: "enum",
    values: ["paired", "lan", "unix", "local"],
    description:
      "Client connection transport path. `local` is on-device work with no server connection.",
  },
  route: {
    kind: "enum",
    values: ["lan", "socks", "system_vpn", "paired"],
    description:
      "Client network route. `system_vpn` is inferred: MagicDNS without a published embedded SOCKS proxy.",
  },
  host_kind: {
    kind: "enum",
    values: ["tailscale", "local", "ip", "dns"],
    description: "Class of the server host. Never the host itself.",
  },
  path_type: {
    kind: "enum",
    values: ["wifi", "cell", "eth", "other", "unknown"],
    description: "Device network interface type.",
  },
  stream: {
    kind: "enum",
    values: ["session", "dictation", "app_events"],
    description: "Server WebSocket stream.",
  },
  message_type: {
    kind: "name",
    description:
      "Protocol message type of a WebSocket frame, or `binary` / `binary_audio` / `client_frame_ignored`.",
  },
  close_code: { kind: "name", description: "WebSocket close code as a decimal string." },
  connection_state: {
    kind: "enum",
    values: ["connected", "connecting", "disconnected", "reconnecting", "no_stream"],
    description:
      "Client focused-stream connection state before a wait began; `no_stream` when no stream existed.",
  },
  stream_state: {
    kind: "name",
    description:
      "Client focused-stream coordinator state (`idle`, `connectingTransport`, `queueSync.initial`, `streaming`, …).",
  },
  intent: {
    kind: "enum",
    values: ["steer", "follow_up"],
    description: "Composer queue intent of a busy send.",
  },
  queue_event: {
    kind: "enum",
    values: ["queue_state", "queue_item_started"],
    description: "Queue frame that revealed a stale client queue.",
  },
  command: { kind: "name", description: "Session command type (`get_queue`, `prompt`, …)." },
  provider: {
    kind: "name",
    description:
      "LLM provider from the session-configured canonical `provider/modelId` route. Omitted when missing or malformed.",
  },
  model: {
    kind: "name",
    description:
      "LLM model id after the first `/` of the session-configured route. Never a family alias.",
  },
  thinking: {
    kind: "enum",
    values: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
    description: "Session-configured Pi thinking level. Per-response reasoning can differ.",
  },
  runtime: {
    kind: "enum",
    values: ["oppi", "durable", "pi-tui"],
    description:
      "Session runtime: `oppi` (classic SDK), `durable` (live durable engine), `pi-tui` (terminal mirror).",
  },
  tool: {
    kind: "name",
    description: "Sanitized tool name. Never arguments, output, or paths.",
  },
  method: { kind: "name", description: "HTTP method." },
  path_pattern: {
    kind: "name",
    route: true,
    description:
      "Normalized HTTP route pattern (`/workspaces/:workspaceId`), or `unregistered`. Never a raw path.",
  },
  status_code: { kind: "name", description: "HTTP status code as a decimal string." },
  notification: {
    kind: "enum",
    values: [
      "blocked",
      "error",
      "notify",
      "pairing_approval",
      "device_enrolled",
      "live_activity_start",
      "live_activity_update",
      "live_activity_end",
    ],
    description: "Push notification kind.",
  },
  run_kind: {
    kind: "enum",
    values: ["due", "manual"],
    description: "What started a schedule run.",
  },
  host_scope: {
    kind: "enum",
    values: ["host", "container"],
    description:
      "Whether `host_*` fields describe the machine or the container Oppi runs in (cgroup limits).",
  },
  load_path: {
    kind: "enum",
    values: [
      "cache_hit",
      "cache_miss",
      "full_reload",
      "first_message_fallback",
      "conversation_stream",
      "open",
      "return_from_chat",
    ],
    description: "How a screen's content was loaded.",
  },
  load_source: {
    kind: "enum",
    values: ["cache", "history", "history_replay", "history_first_message_fallback"],
    description: "Where the timeline reducer rebuilt its state from.",
  },
  row_type: {
    kind: "name",
    description: "Timeline row type (`tool`, `load_more`, `quiet_work`, …).",
  },
  content_type: {
    kind: "name",
    description: "Kind of rendered or shared content (`code`, `diff`, `markdown`, …).",
  },
  output_size: {
    kind: "bucket",
    source: "bytes",
    buckets: SIZE_BUCKETS,
    description: "Size class of a tool row's output.",
  },
  input_size: {
    kind: "bucket",
    source: "bytes",
    buckets: SIZE_BUCKETS,
    description: "Size class of the input a render step processed.",
  },
  render_mode: {
    kind: "name",
    description: "Render strategy (`bash.output.deferred`, `code.highlight`, `diff.stream`, …).",
  },
  measure: {
    kind: "name",
    description: "Tool row measurement pass (`width.<name>`, `viewport.<name>`).",
  },
  language: { kind: "name", description: "Syntax-highlight language." },
  surface: {
    kind: "name",
    description:
      "UI surface where the event happened (`inline`, `expanded`, `fullscreen.markdown`, …).",
  },
  screen: {
    kind: "name",
    description: "Coarse client screen label from the diagnostic context.",
  },
  agents: {
    kind: "enum",
    values: ["running", "idle"],
    description: "Whether any agent session was running on the device.",
  },
  voice: {
    kind: "enum",
    values: ["on", "off"],
    description: "Whether voice input was active.",
  },
  voice_engine: {
    kind: "enum",
    values: ["speech", "dictation", "server"],
    description:
      "Client voice input engine: Apple SpeechTranscriber, Apple DictationTranscriber, or server dictation.",
  },
  locale: { kind: "name", description: "BCP 47 dictation locale." },
  trigger: {
    kind: "name",
    description: "Call site that started the operation (`chat_view_task`, `composer_mic`, …).",
  },
  model_path: {
    kind: "enum",
    values: ["warm_cache", "cold", "join_prewarm", "dictation_audio_ws"],
    description: "How the dictation model or stream was obtained at setup.",
  },
  stt_provider: {
    kind: "name",
    description: "Speech-to-text provider id (`apple_modern_speech`, `stt_mlx_server`, …).",
  },
  stt_provider_kind: {
    kind: "enum",
    values: ["on_device", "local_server"],
    description: "Where speech-to-text runs.",
  },
  stt_backend: { kind: "name", description: "Speech-to-text backend name." },
  stt_model: { kind: "name", description: "Speech-to-text model name." },
  result_type: {
    kind: "name",
    description: "Kind of the first transcript event (`partial`, `final`, …).",
  },
  audio_category: { kind: "name", description: "AVAudioSession category raw value." },
  audio_mode: { kind: "name", description: "AVAudioSession mode raw value." },
  audio_inputs: {
    kind: "name",
    description:
      "AVAudioSession input port types joined with `/`. Port types only, never names or hardware ids.",
  },
  audio_outputs: {
    kind: "name",
    description: "AVAudioSession output port types joined with `/`.",
  },
  audio_route: {
    kind: "enum",
    values: ["built_in_fallback"],
    description: "Set when capture fell back to the built-in microphone.",
  },
  media_kind: {
    kind: "enum",
    values: ["video", "audio", "image", "unknown"],
    description: "Kind of media being played.",
  },
  playback_source: {
    kind: "name",
    description: "Where played media came from (`speech`, `stream_pcm`, `authenticated_media`, …).",
  },
  playback_mode: {
    kind: "name",
    description: "How playback was presented (`manual`, `autoplay`, `fullscreen`, …).",
  },
  response_encoding: {
    kind: "enum",
    values: ["ask", "select", "confirm", "input"],
    description: "How an ask card encodes its answer.",
  },
  export_format: { kind: "name", description: "Share export format (`image`, `pdf`, `source`)." },
  origin_surface: {
    kind: "enum",
    values: ["sheet", "intent"],
    description: "Where a quick session was started: the in-app sheet or an App Intent.",
  },
  workspace_selection: {
    kind: "name",
    description: "How a workspace was chosen (`last_used`, `default`, `first_available`, …).",
  },
  worktree: {
    kind: "enum",
    values: ["main", "other"],
    description: "Whether a session launched on the main worktree.",
  },
  session_engine: {
    kind: "enum",
    values: ["classic", "durable"],
    description: "Session engine chosen at launch.",
  },
} as const satisfies Readonly<Record<string, TagDef>>;

export type TagKey = keyof typeof TAGS;

// ── Shared tag sets ──

const NETWORK_ROUTE_TAGS = {
  route: {},
  host_kind: {},
  path_type: {},
  transport: { values: ["paired", "lan", "unix"] },
} as const;

const SERVER_ROUTING_TAGS = {
  runtime: { required: true },
  provider: {},
  model: {},
  thinking: {},
} as const;

/** Dictation context every app dictation event carries. */
const DICTATION_TAGS = {
  voice_engine: { required: true },
  locale: {},
  trigger: {},
} as const;

/** Provider and audio-route context known once dictation setup has run. */
const DICTATION_PROVIDER_TAGS = {
  model_path: {},
  stt_provider: {},
  stt_provider_kind: {},
  stt_backend: {},
  stt_model: {},
  audio_category: {},
  audio_mode: {},
  audio_inputs: {},
  audio_outputs: {},
  audio_route: {},
} as const;

const SERVER_STT_TAGS = {
  stt_provider: { required: true },
  stt_backend: { required: true },
  stt_model: { required: true },
} as const;

const SHARE_POLICY_FIELDS = {
  redact_emails: "bool",
  redact_phones: "bool",
  redact_user_paths: "bool",
  redact_ip_addresses: "bool",
  redact_jwt_bearer: "bool",
  redact_names: "bool",
  redact_skills: "bool",
} as const;

const OPT_COUNT = { unit: "count", optional: true } as const;
const OPT_MS = { unit: "ms", optional: true } as const;
const OPT_MB = { unit: "mb", optional: true } as const;
const OPT_BOOL = { unit: "bool", optional: true } as const;

/** The longest plausible foreground operation; longer samples spanned an app suspension. */
const SUSPENSION_CEILING_MS = 5_000;

/** The longest plausible screen load; a longer sample waited out a backgrounding or an abandoned visit. */
const LOAD_CEILING_MS = 60_000;

// ── Events ──

const EVENTS = {
  // ─── App: session and chat responsiveness ───
  "app.ttft": {
    description: "How long did the user wait for the first assistant token of a turn?",
    group: "ux",
    fields: { duration_ms: "ms" },
    tags: { provider: {}, model: {} },
    slo: [{ field: "duration_ms", tm99: 20_000, label: "Time to first token" }],
  },
  "app.catchup": {
    description: "How long did catch-up take when (re)subscribing, and how did it resolve?",
    group: "ux",
    fields: { duration_ms: "ms" },
    tags: {
      result: {
        required: true,
        values: [
          "missing_epoch_baseline",
          "missing_epoch",
          "seq_regression",
          "epoch_baseline",
          "epoch_changed",
          "no_gap",
          "fetch_failed",
          "not_live",
          "epoch_mismatch",
          "ring_miss",
          "applied",
        ],
      },
    },
    slo: [{ field: "duration_ms", tm99: 500, label: "Reconnection catch-up" }],
  },
  "app.cache_load": {
    description: "How long did loading the cached timeline take?",
    group: "ux",
    fields: { duration_ms: "ms", hit: "bool", events: "count" },
    slo: [{ field: "duration_ms", tm99: 200, label: "Cache load" }],
  },
  "app.reducer_load": {
    description: "How long did rebuilding the timeline reducer take?",
    group: "ux",
    fields: { duration_ms: "ms", events: "count", items: "count" },
    tags: { load_source: { required: true } },
    slo: [{ field: "duration_ms", tm99: 200, label: "Timeline rebuild" }],
  },
  "app.session_load": {
    description: "How long from selecting a session until its content was visible?",
    group: "ux",
    fields: { duration_ms: "ms", items: "count" },
    tags: {
      load_path: {
        required: true,
        values: [
          "cache_hit",
          "cache_miss",
          "full_reload",
          "first_message_fallback",
          "conversation_stream",
        ],
      },
    },
    slo: [{ field: "duration_ms", tm99: 600, label: "Session load" }],
  },
  "app.fresh_content_lag": {
    description: "How long until the timeline showed fresh content after connecting?",
    group: "ux",
    fields: { duration_ms: "ms", cached: "bool" },
    tags: {
      reason: {
        required: true,
        values: [
          "cache_hit",
          "conversation_stream",
          "reconnect_conversation_stream",
          "reconnect_no_gap",
          "reconnect_applied",
          "reconnect_full_reload_scheduled",
          "stream_seq",
          "history_empty",
          "history_applied_empty",
          "history_deferred_to_live",
          "history_unchanged",
          "history_applied",
          "history_replayed",
          "history_first_message_fallback",
        ],
      },
      transport: { values: ["paired", "lan", "unix"] },
    },
    slo: [{ field: "duration_ms", tm99: 1_000, label: "Fresh content lag" }],
  },
  "app.session_switch": {
    description: "How long from tapping a session row until chat content was visible?",
    group: "ux",
    fields: { duration_ms: "ms", cached: "bool" },
    emit: [{ field: "duration_ms", max: LOAD_CEILING_MS }],
    slo: [{ field: "duration_ms", tm99: 600, label: "Session switch" }],
  },
  "app.trace_fetch": {
    description: "How long did fetching and decoding a trace page take?",
    group: "ux",
    fields: { duration_ms: "ms", trace_events: OPT_COUNT },
    tags: { status: { required: true, values: ["ok", "error"] }, error_kind: {} },
    slo: [
      { field: "duration_ms", tm99: 1_500, label: "Trace fetch (ok)", where: { status: ["ok"] } },
    ],
  },
  "app.thread_load": {
    description: "How long from opening a thread until its snapshot was applied or failed?",
    group: "ux",
    fields: { duration_ms: "ms" },
    tags: {
      phase: { required: true, values: ["initial", "refresh"] },
      status: { required: true, values: ["ok", "error"] },
      error_kind: {},
    },
  },
  "app.workspace_load": {
    description: "How long until the workspace screen was usable?",
    group: "ux",
    fields: { duration_ms: "ms" },
    tags: { load_path: { required: true, values: ["open", "return_from_chat"] } },
    emit: [{ field: "duration_ms", max: LOAD_CEILING_MS }],
    slo: [{ field: "duration_ms", tm99: 1_000, label: "Workspace load" }],
  },

  // ─── App: connection, commands, and queue ───
  "app.ws_wait": {
    description: "How long did the client wait for the focused session stream to connect?",
    group: "connection",
    fields: { duration_ms: "ms", socks_generation: "count" },
    tags: {
      ...NETWORK_ROUTE_TAGS,
      connection_state: { required: true },
      result: { required: true, values: ["already_connected", "connected", "timeout"] },
    },
    slo: [{ field: "duration_ms", tm99: 1_000, label: "Client WS connected wait" }],
  },
  "app.network_handshake": {
    description: "How long did an HTTPS candidate handshake take on each route?",
    group: "connection",
    fields: { duration_ms: "ms", socks_generation: "count" },
    tags: {
      ...NETWORK_ROUTE_TAGS,
      status: { required: true, values: ["ok", "error"] },
      error_kind: {},
    },
  },
  "app.ws_ping": {
    description: "What is the client WebSocket ping round-trip time on each route?",
    group: "connection",
    fields: { rtt_ms: "ms", socks_generation: "count" },
    tags: NETWORK_ROUTE_TAGS,
    emit: [{ field: "rtt_ms", min: 0 }],
  },
  "app.command": {
    description:
      "How long did a session command take to send and to resolve? Fire-and-forget commands have no round trip.",
    group: "connection",
    fields: { send_ms: "ms", roundtrip_ms: OPT_MS },
    tags: {
      command: { required: true },
      transport: { required: true, values: ["paired", "lan", "unix"] },
      status: { required: true, values: ["ok", "cancelled", "error"] },
      error_kind: {},
    },
    // Successful get_queue polls are routine; keep only slow ones.
    emit: [{ field: "roundtrip_ms", min: 500, where: { command: ["get_queue"], status: ["ok"] } }],
  },
  "app.command_resolve_lag": {
    description: "How long from a command_result frame arriving to its waiter resolving?",
    group: "connection",
    fields: { lag_ms: "ms" },
    tags: {
      command: { required: true },
      transport: { required: true, values: ["paired", "lan", "unix"] },
      status: { required: true, values: ["ok", "error"] },
    },
    emit: [{ field: "lag_ms", min: 50, where: { command: ["get_queue"], status: ["ok"] } }],
  },
  "app.queue_sync": {
    description: "How long did refreshing the queued steer/follow-up snapshot take?",
    group: "connection",
    fields: { duration_ms: "ms" },
    tags: {
      transport: { required: true, values: ["paired", "lan", "unix"] },
      phase: { required: true, values: ["initial", "deferred"] },
      status: { required: true, values: ["ok", "cancelled", "error"] },
      error_kind: {},
    },
    slo: [{ field: "duration_ms", tm99: 500, label: "Queue sync (ok)", where: { status: ["ok"] } }],
  },
  "app.message_queue_ack": {
    description:
      "How long from a busy send to server acknowledgement? A turn that already ended prompts it normally.",
    group: "connection",
    fields: { duration_ms: "ms" },
    tags: {
      intent: { required: true },
      transport: { required: true, values: ["paired", "lan", "unix"] },
      status: { required: true, values: ["ok", "error"] },
      error_kind: {},
    },
    slo: [
      {
        field: "duration_ms",
        tm99: 300,
        label: "Message queue ack (ok)",
        where: { status: ["ok"] },
      },
    ],
  },
  "app.message_queue_stale_drop": {
    description: "Did the client drop a queue update because its queue state was stale?",
    group: "connection",
    fields: { incoming_version: "count", current_version: "count" },
    tags: { queue_event: { required: true } },
  },
  "app.message_queue_start_miss": {
    description: "Did a queue item start that the client never saw queued?",
    group: "connection",
    fields: { queue_version: "count" },
    tags: { intent: { required: true } },
  },
  "app.app_event_stream_connect": {
    description: "How long until global app updates, attention cards, and list events were live?",
    group: "connection",
    fields: { duration_ms: "ms", attempt: "count", snapshot_required: "bool" },
    slo: [{ field: "duration_ms", tm99: 1_000, label: "App-event stream ready" }],
  },
  "app.app_event_stream_reconnect": {
    description: "Why and how often did the global app-event stream schedule a reconnect?",
    group: "connection",
    fields: { attempt: "count", socks_generation: "count" },
    tags: {
      ...NETWORK_ROUTE_TAGS,
      reason: {
        required: true,
        values: [
          "receive_error",
          "handshake_http",
          "protocol_close",
          "recoverable_receive",
          "ping_watchdog",
          "auth_current_token",
          "auth_refresh",
        ],
      },
      close_code: {},
    },
  },
  "app.app_event_stream_decode_error": {
    description: "Did a global app-event stream frame fail to decode?",
    group: "connection",
    fields: {},
    tags: { error_kind: { required: true, values: ["decode", "network", "other"] } },
  },

  // ─── App: rendering ───
  "app.timeline_apply": {
    description: "How long did a timeline snapshot apply take during streaming?",
    group: "rendering",
    fields: { duration_ms: "ms", items: "count", changed: "count" },
    emit: [{ field: "duration_ms", min: 4, max: SUSPENSION_CEILING_MS }],
    slo: [{ field: "duration_ms", tm99: 8.3, label: "Timeline apply (120 Hz)" }],
  },
  "app.timeline_layout": {
    description: "How long did timeline layout take during streaming?",
    group: "rendering",
    fields: { duration_ms: "ms", items: "count" },
    emit: [{ field: "duration_ms", min: 2, max: SUSPENSION_CEILING_MS }],
    slo: [{ field: "duration_ms", tm99: 8.3, label: "Timeline layout (120 Hz)" }],
  },
  "app.cell_configure": {
    description: "How long did configuring a timeline row take, especially large tool output?",
    group: "rendering",
    fields: { duration_ms: "ms", expanded: OPT_BOOL },
    tags: { row_type: { required: true }, tool: {}, content_type: {}, output_size: {} },
    emit: [{ field: "duration_ms", min: 1, max: SUSPENSION_CEILING_MS }],
    slo: [{ field: "duration_ms", tm99: 8.3, label: "Cell configure (120 Hz)" }],
  },
  "app.render_strategy": {
    description: "How long did highlighting, ANSI parsing, or diff building take for a tool row?",
    group: "rendering",
    fields: { duration_ms: "ms" },
    tags: { render_mode: { required: true }, input_size: { required: true }, language: {} },
    emit: [{ field: "duration_ms", min: 1, max: SUSPENSION_CEILING_MS }],
  },
  "app.tool_row_measure": {
    description: "How long did measuring a tool row's width or viewport take?",
    group: "rendering",
    fields: { duration_ms: "ms" },
    tags: { measure: { required: true }, input_size: { required: true } },
    emit: [{ field: "duration_ms", min: 1 }],
  },
  "app.markdown_streaming": {
    description: "How long did one streaming markdown parse, build, and apply cycle take?",
    group: "rendering",
    fields: { duration_ms: "ms", segments: "count" },
    tags: { surface: { required: true } },
    emit: [{ field: "duration_ms", min: 1 }],
    slo: [{ field: "duration_ms", tm99: 8.3, label: "Markdown stream (120 Hz)" }],
  },
  "app.timeline_jank": {
    description: "What share of timeline apply cycles in a session missed the frame budget?",
    group: "rendering",
    fields: { jank_pct: "pct", cycles: "count", hitches: "count" },
    emit: [{ field: "cycles", min: 1 }],
    slo: [{ field: "jank_pct", tm99: 25, label: "Scroll jank %" }],
  },
  "app.coalescer_window": {
    description:
      "How much stream traffic did the delta coalescer flush per window of 200 flushes (or a non-trivial partial drain)?",
    group: "rendering",
    fields: { flushes: "count", events: "count", payload_bytes: "bytes" },
  },
  "app.diff_reader_session": {
    description: "How fast did a review diff open and how smoothly did it scroll?",
    group: "rendering",
    fields: {
      open_ms: "ms",
      lines: "count",
      chunks: "count",
      content_width_points: "count",
      scroll_frames: "count",
      hitches: "count",
      hitch_ratio: "ratio",
      worst_frame_ms: "ms",
    },
  },

  // ─── App: session list ───
  "app.session_list_compute": {
    description: "How long did computing the session list view data take?",
    group: "session_list",
    fields: { duration_ms: "ms", active_sessions: "count", stopped_sessions: "count" },
    emit: [{ field: "duration_ms", min: 1 }],
    slo: [{ field: "duration_ms", tm99: 10, label: "List compute" }],
  },
  "app.session_list_row_compute": {
    description: "How long did computing the visible session rows take?",
    group: "session_list",
    fields: { duration_ms: "ms", rows: "count" },
    emit: [{ field: "duration_ms", min: 1 }],
  },
  "app.session_list_body_rate": {
    description: "How often did the session list body re-evaluate in a 5 s window (store churn)?",
    group: "session_list",
    fields: { evaluations: "count" },
    slo: [{ field: "evaluations", tm99: 12, label: "List body evals/5s" }],
  },

  // ─── App: workload snapshot ───
  "app.session_usage": {
    description: "How large has a session grown (messages, tokens, edits, context)?",
    group: "workload",
    fields: {
      message_count: "count",
      input_tokens: "count",
      output_tokens: "count",
      mutating_tool_calls: "count",
      files_changed: "count",
      context_tokens: "count",
      context_window: "count",
    },
    tags: { provider: {}, model: {} },
  },

  // ─── App: dictation and voice ───
  "app.dictation_prewarm": {
    description: "How long did prewarming the voice pipeline take?",
    group: "dictation_ux",
    fields: { duration_ms: "ms" },
    tags: {
      ...DICTATION_TAGS,
      status: { required: true, values: ["ok", "cancelled", "error"] },
      error_kind: {},
    },
    slo: [
      {
        field: "duration_ms",
        tm99: 100,
        label: "Dictation prewarm (ok)",
        where: { status: ["ok"] },
      },
    ],
  },
  "app.dictation_setup": {
    description:
      "How long from starting dictation to recording, per setup phase? Failed or cancelled setups carry only total_ms.",
    group: "dictation_ux",
    fields: {
      total_ms: "ms",
      model_ready_ms: OPT_MS,
      transcriber_create_ms: OPT_MS,
      analyzer_start_ms: OPT_MS,
      audio_session_ms: OPT_MS,
      audio_start_ms: OPT_MS,
      audio_sample_rate: OPT_COUNT,
    },
    tags: {
      ...DICTATION_TAGS,
      ...DICTATION_PROVIDER_TAGS,
      status: { required: true, values: ["ok", "cancelled", "error"] },
      error_kind: {},
    },
    slo: [
      { field: "total_ms", tm99: 350, label: "Dictation setup (ok)", where: { status: ["ok"] } },
    ],
  },
  "app.dictation_first_result": {
    description: "How long until the user saw the first transcript feedback?",
    group: "dictation_ux",
    fields: { duration_ms: "ms" },
    tags: { ...DICTATION_TAGS, ...DICTATION_PROVIDER_TAGS, result_type: {} },
    slo: [{ field: "duration_ms", tm99: 6_000, label: "Dictation first result" }],
  },
  "app.dictation_end": {
    description:
      "How did a completed dictation take finish: finalize latency, length, and quality?",
    group: "dictation_ux",
    fields: {
      finalize_ms: "ms",
      session_ms: "ms",
      audio_duration_ms: "ms",
      result_updates: "count",
      preview_final_delta_ratio: "ratio",
      input_level_peak_ratio: "ratio",
    },
    tags: { ...DICTATION_TAGS, ...DICTATION_PROVIDER_TAGS },
    slo: [
      { field: "finalize_ms", tm99: 500, label: "Dictation finalize" },
      { field: "preview_final_delta_ratio", tm99: 0.15, label: "Preview/final delta" },
    ],
  },
  "app.dictation_capture_error": {
    description:
      "Did audio capture fail while dictating? Setup failures are app.dictation_setup errors.",
    group: "dictation_ux",
    fields: {},
    tags: { ...DICTATION_TAGS, ...DICTATION_PROVIDER_TAGS, error_kind: { required: true } },
  },
  "app.dictation_cancel": {
    description: "Did the user cancel a dictation take after recording started?",
    group: "dictation_ux",
    fields: {},
    tags: { ...DICTATION_TAGS, ...DICTATION_PROVIDER_TAGS },
  },
  "app.live_voice_leftover_call": {
    description: "Did iOS keep CallKit calls listed after their Live Voice call was over?",
    group: "media",
    fields: { calls: "count" },
    tags: { phase: { required: true, values: ["call_start", "call_end", "dictation_start"] } },
    emit: [{ field: "calls", min: 1 }],
  },
  "app.live_voice_call_playback": {
    description: "How smoothly did Live Voice call audio play?",
    group: "media",
    fields: {
      chunks: "count",
      received_ms: "ms",
      max_gap_ms: "ms",
      underruns: "count",
      flushes: "count",
      min_prime_ms: "ms",
      final_prime_ms: "ms",
      max_lag_ms: "ms",
      audio_restarts: "count",
      echo_cancellation: "bool",
    },
  },

  // ─── App: attention, media, share, quick session ───
  "app.voice_playback_start": {
    description: "How long did voice replies and replayable voice media take to start playing?",
    group: "media",
    fields: { duration_ms: "ms" },
    tags: { playback_source: { required: true }, playback_mode: {} },
  },
  "app.voice_playback_error": {
    description: "Where did voice playback fail?",
    group: "media",
    fields: {},
    tags: {
      playback_source: { required: true },
      phase: { required: true, values: ["start", "load", "stream", "activate", "chunk"] },
      error_kind: { required: true },
    },
  },
  "app.media_playback_start": {
    description: "How long from player setup to playable video or audio?",
    group: "media",
    fields: { duration_ms: "ms" },
    tags: { media_kind: { required: true }, playback_source: {}, playback_mode: {} },
    slo: [{ field: "duration_ms", tm99: 2_000, label: "Media playback start" }],
  },
  "app.media_playback_error": {
    description: "Where did a media preview or player fail?",
    group: "media",
    fields: {},
    tags: {
      media_kind: { required: true },
      playback_source: {},
      phase: { required: true, values: ["source", "player_item", "player_state", "stall"] },
      error_kind: { required: true },
    },
  },
  "app.ask_response": {
    description: "How long did a visible ask card block the agent before answer or ignore?",
    group: "media",
    fields: {
      duration_ms: "ms",
      questions: "count",
      answered: "count",
      ignored: "count",
      multi_select_questions: "count",
      selected: "count",
      custom: "bool",
      allow_custom: "bool",
    },
    tags: {
      result: { required: true, values: ["answered", "empty", "ignored"] },
      surface: {},
      response_encoding: {},
    },
  },
  "app.share_export": {
    description: "How long did rendering share-sheet content take?",
    group: "media",
    fields: { duration_ms: "ms" },
    tags: { export_format: { required: true }, content_type: {} },
    emit: [{ field: "duration_ms", min: 1 }],
  },
  "app.share_prepare": {
    description: "How long did the shared-session redaction preflight take, and what did it find?",
    group: "media",
    fields: {
      duration_ms: "ms",
      findings: OPT_COUNT,
      replacements: OPT_COUNT,
      blocked: OPT_BOOL,
      can_publish: OPT_BOOL,
      ...SHARE_POLICY_FIELDS,
    },
    tags: { status: { required: true, values: ["ok", "error"] }, error_kind: {} },
  },
  "app.share_publish": {
    description: "How long did publishing a shared session take?",
    group: "media",
    fields: {
      duration_ms: "ms",
      findings: OPT_COUNT,
      replacements: OPT_COUNT,
      ...SHARE_POLICY_FIELDS,
    },
    tags: { status: { required: true, values: ["ok", "error"] }, error_kind: {} },
  },
  "app.quick_session_create": {
    description:
      "How long did creating a quick session take, and did it fail? An intent whose prompt was not delivered is status=error, error_kind=prompt_delivery.",
    group: "media",
    fields: {
      duration_ms: "ms",
      has_message: "bool",
      has_model: "bool",
      has_attachments: OPT_BOOL,
      has_repo_refs: OPT_BOOL,
      has_agent: OPT_BOOL,
      incognito: OPT_BOOL,
    },
    tags: {
      origin_surface: { required: true },
      workspace_selection: {},
      worktree: {},
      session_engine: {},
      status: { required: true, values: ["ok", "error"] },
      error_kind: {},
    },
  },

  // ─── App: device ───
  "app.device_resources": {
    description:
      "What did the app cost in CPU and memory, and how much headroom was left, on each screen and state? Sampled every 10 s.",
    group: "device",
    fields: {
      cpu_pct: { unit: "pct", optional: true },
      memory_mb: OPT_MB,
      memory_available_mb: "mb",
      thermal_state: "count",
    },
    tags: { screen: {}, stream_state: {}, agents: {}, voice: {} },
    slo: [
      { field: "cpu_pct", tm99: 20, label: "CPU usage %" },
      { field: "memory_mb", tm99: 250, label: "Memory footprint" },
      {
        field: "memory_available_mb",
        tm99: 100,
        label: "Memory avail (low=bad)",
        lowerIsBad: true,
      },
      { field: "thermal_state", tm99: 1, label: "Thermal (0-3)" },
    ],
  },
  "app.memory_warning": {
    description: "How large was the app when iOS sent a memory warning, and what did it free?",
    group: "device",
    fields: {
      footprint_before_mb: OPT_MB,
      footprint_after_mb: OPT_MB,
      cache_entries: "count",
      cache_bytes: "bytes",
    },
    tags: { screen: {} },
  },
  "app.foreground": {
    description: "How large was the app when it returned to the foreground?",
    group: "device",
    fields: { footprint_mb: OPT_MB, reconnect: "bool" },
    tags: { screen: {} },
  },
  "app.main_thread_stall_detected": {
    description: "Did the main thread miss the watchdog probe, and how large was the app?",
    group: "device",
    fields: { threshold_ms: "ms", footprint_mb: OPT_MB, sequence: "count" },
    tags: { screen: {} },
  },
  "app.main_thread_stall_recovered": {
    description: "How long did a detected main-thread stall last?",
    group: "device",
    fields: { duration_ms: "ms", sequence: "count" },
    tags: { screen: {} },
  },

  // ─── Server: connection ───
  "server.ws_handshake": {
    description: "How long did a WebSocket upgrade take on the server?",
    group: "connection",
    fields: { duration_ms: "ms" },
    tags: { stream: { required: true } },
    slo: [{ field: "duration_ms", tm99: 100, label: "Server WS handshake" }],
  },
  "server.ws_first_message": {
    description: "How long from WebSocket open to the first client message?",
    group: "server_ops",
    fields: { duration_ms: "ms" },
    tags: { stream: { required: true } },
  },
  "server.ws_ping": {
    description: "What is the server-initiated ping round-trip time?",
    group: "server_ops",
    fields: { rtt_ms: "ms" },
  },
  "server.ws_ping_timeout": {
    description: "Did the server terminate a dead connection after missed pongs?",
    group: "server_ops",
    fields: {},
  },
  "server.ws_session": {
    description: "How long did a WebSocket connection live, how busy was it, and how did it close?",
    group: "server_ops",
    fields: { duration_ms: "ms", messages_sent: "count", messages_received: "count" },
    tags: { stream: { required: true }, close_code: { required: true } },
  },
  "server.ws_message_sent": {
    description: "How many frames did the server send, by stream and message type?",
    group: "server_ops",
    fields: { messages: "count" },
    tags: { stream: { required: true }, message_type: { required: true } },
    storage: { aggregate: { messages: "sum" } },
  },
  "server.ws_message_received": {
    description: "How many frames and binary bytes did the server receive, by stream and type?",
    group: "server_ops",
    fields: { messages: "count", binary_bytes: "bytes" },
    tags: { stream: { required: true }, message_type: { required: true } },
    storage: { aggregate: { messages: "sum", binary_bytes: "sum" } },
  },
  "server.session_subscribe": {
    description: "How long did the server's session subscribe and catch-up path take?",
    group: "connection",
    fields: {
      duration_ms: "ms",
      catchup_requested: "bool",
      catchup_complete: "bool",
      started_session: "bool",
      pending_ui_requests: "count",
    },
    tags: { status: { required: true, values: ["ok", "error"] } },
    slo: [{ field: "duration_ms", tm99: 300, label: "Server session subscribe" }],
  },
  "server.catchup": {
    description: "Did the session event ring serve a catch-up, and how many events did it replay?",
    group: "server_ops",
    fields: { events: "count" },
    tags: { result: { required: true, values: ["replayed", "miss"] } },
  },
  "server.broadcast_fanout": {
    description: "What was the peak subscriber count for durable broadcasts, by message type?",
    group: "server_ops",
    fields: { subscribers: "count" },
    tags: { message_type: { required: true } },
    storage: { aggregate: { subscribers: "max" } },
  },

  // ─── Server: session lifecycle ───
  "server.session_create": {
    description: "How long did creating a session runtime take?",
    group: "server_ops",
    fields: { duration_ms: "ms" },
  },
  "server.sdk_session_setup": {
    description: "How did classic SDK session creation split between SDK setup and extension bind?",
    group: "server_ops",
    fields: { sdk_ms: "ms", bind_ms: "ms" },
  },
  "server.session_end": {
    description: "Why did sessions end?",
    group: "server_ops",
    fields: {},
    tags: {
      reason: {
        required: true,
        values: [
          "completed",
          "stopped",
          "error",
          "idle_timeout",
          "server_restart",
          "store_failed",
          "other",
        ],
      },
    },
  },
  "server.session_title": {
    description: "How long did automatic session title generation take?",
    group: "server_ops",
    fields: { duration_ms: "ms", tokens: "count" },
    tags: { model: {}, status: { required: true, values: ["ok", "error", "timeout"] } },
  },
  "server.ask_round_trip": {
    description: "How long from a direct ask UI request to the user's answer?",
    group: "media",
    fields: { duration_ms: "ms", questions: "count" },
    tags: { status: { required: true, values: ["ok", "cancelled"] } },
  },

  // ─── Server: agent workload ───
  "server.turn": {
    description:
      "How long did a full agent turn take, how many tools did it run, and did it end in an error?",
    group: "workload",
    fields: { duration_ms: OPT_MS, tool_calls: OPT_COUNT },
    tags: {
      ...SERVER_ROUTING_TAGS,
      status: { required: true, values: ["ok", "error"] },
      error_kind: {
        values: [
          "request_too_large",
          "overloaded",
          "rate_limit",
          "auth",
          "timeout",
          "network",
          "json_parse",
          "terminated",
          "other",
        ],
      },
    },
  },
  "server.turn_ttft": {
    description: "How long from agent_start to the first text or thinking token on the server?",
    group: "workload",
    fields: { duration_ms: "ms" },
    tags: SERVER_ROUTING_TAGS,
  },
  "server.turn_usage": {
    description: "How many tokens and how much money did turns use, per route?",
    group: "workload",
    fields: { input_tokens: "count", output_tokens: "count", cost_usd_micros: "usd_micros" },
    tags: SERVER_ROUTING_TAGS,
    storage: {
      aggregate: { input_tokens: "sum", output_tokens: "sum", cost_usd_micros: "sum" },
    },
  },
  "server.tool_call": {
    description:
      "How long did a tool call take and did it fail mechanically? Unpaired ends have no duration.",
    group: "workload",
    fields: { duration_ms: OPT_MS },
    tags: {
      ...SERVER_ROUTING_TAGS,
      tool: { required: true },
      status: { required: true, values: ["ok", "error"] },
    },
  },
  "server.auto_retry": {
    description: "How often did Pi auto-retry a turn?",
    group: "workload",
    fields: { attempt: "count" },
    tags: SERVER_ROUTING_TAGS,
  },
  "server.compaction": {
    description: "How long did auto-compaction take, and did it finish?",
    group: "workload",
    fields: { duration_ms: OPT_MS },
    tags: {
      ...SERVER_ROUTING_TAGS,
      status: { required: true, values: ["ok", "error", "cancelled"] },
      result: { values: ["will_retry"] },
    },
  },

  // ─── Server: operations ───
  "server.http_request": {
    description:
      "How long did an HTTP request take and how many body bytes did it write? Fast successful routine routes are omitted.",
    group: "server_ops",
    fields: { duration_ms: "ms", response_bytes: { unit: "bytes", optional: true } },
    tags: {
      method: { required: true },
      path_pattern: { required: true },
      status_code: { required: true },
    },
  },
  "server.mcp_connect": {
    description: "How long did the first MCP connect take on a durable session, and did it fail?",
    group: "server_ops",
    fields: { duration_ms: "ms" },
    tags: {
      status: { required: true, values: ["ok", "error"] },
      error_kind: { values: ["auth", "connect", "config"] },
    },
  },
  "server.schedule_run": {
    description: "How long did dispatching a schedule run take, and why did it fail?",
    group: "server_ops",
    fields: { duration_ms: "ms" },
    tags: {
      run_kind: { required: true },
      status: { required: true, values: ["ok", "error"] },
      reason: { values: ["lease_lost", "not_found", "launch_in_progress", "other"] },
    },
  },
  "server.push": {
    description: "How did a push send resolve, and how long did seal-and-relay take?",
    group: "server_ops",
    fields: { send_ms: OPT_MS },
    tags: {
      notification: { required: true },
      result: {
        required: true,
        values: [
          "delivered",
          "gone",
          "rejected",
          "unavailable",
          "failed",
          "throttled",
          "no_activity",
        ],
      },
    },
  },

  // ─── Server: dictation ───
  "server.dictation_first_audio": {
    description: "How long from dictation_start to the first audio frame?",
    group: "dictation_backend",
    fields: { duration_ms: "ms" },
    tags: SERVER_STT_TAGS,
  },
  "server.dictation_first_result": {
    description:
      "How long until the first visible streaming transcript, and how much audio had arrived?",
    group: "dictation_backend",
    fields: { duration_ms: "ms", audio_ms: "ms" },
    tags: SERVER_STT_TAGS,
  },
  "server.dictation_finalize": {
    description:
      "How did a server dictation session finish: session length, final STT latency and real-time factor, and total finalize time?",
    group: "dictation_backend",
    fields: {
      session_ms: "ms",
      audio_duration_ms: "ms",
      result_updates: "count",
      stt_ms: OPT_MS,
      stt_audio_ratio: { unit: "ratio", optional: true },
      finalize_ms: OPT_MS,
    },
    tags: {
      ...SERVER_STT_TAGS,
      status: { required: true, values: ["ok", "error"] },
      result: { values: ["transcribed", "no_audio"] },
      error_kind: { values: ["stt"] },
    },
    slo: [
      { field: "stt_ms", tm99: 200, label: "STT inference" },
      { field: "stt_audio_ratio", tm99: 0.1, label: "STT real-time factor" },
      { field: "finalize_ms", tm99: 250, label: "Finalize total" },
    ],
  },
  "server.dictation_stream_error": {
    description: "Did the dictation stream refuse a connection or a message?",
    group: "dictation_backend",
    fields: {},
    tags: {
      reason: { required: true, values: ["dictation_unavailable", "unsupported_message"] },
    },
  },

  // ─── Server: resources ───
  "server.resources": {
    description:
      "How much CPU, memory, event-loop delay, and concurrency did the server and its host use? Sampled every 30 s while server metrics are on.",
    group: "server",
    fields: {
      cpu_total_pct: "pct",
      cpu_user_pct: "pct",
      cpu_system_pct: "pct",
      rss_mb: "mb",
      heap_used_mb: "mb",
      heap_total_mb: "mb",
      external_mb: "mb",
      sessions_busy: "count",
      sessions_ready: "count",
      sessions_starting: "count",
      sessions_total: "count",
      sessions_peak: "count",
      ws_connections: "count",
      event_loop_p50_ms: "ms",
      event_loop_p95_ms: "ms",
      event_loop_p99_ms: "ms",
      event_loop_max_ms: "ms",
      event_ring_peak_ratio: { unit: "ratio", optional: true },
      host_cpu_pct: { unit: "pct", optional: true },
      host_cpu_cores: OPT_COUNT,
      host_cpu_limited: OPT_BOOL,
      host_load1: OPT_COUNT,
      host_mem_used_mb: OPT_MB,
      host_mem_total_mb: OPT_MB,
      host_mem_limited: OPT_BOOL,
      host_disk_used_mb: OPT_MB,
      host_disk_total_mb: OPT_MB,
    },
    tags: { host_scope: {} },
    slo: [
      { field: "cpu_total_pct", tm99: 10, label: "Server CPU %" },
      { field: "rss_mb", tm99: 800, label: "Server RSS" },
      { field: "heap_used_mb", tm99: 200, label: "Server heap" },
      { field: "ws_connections", tm99: 5, label: "WS connections" },
      { field: "sessions_total", tm99: 8, label: "Active sessions" },
      // Stall gate, not the typical interval. TM99 of the interval max was 50 ms on
      // 2026-10-06 and 111 ms on 2026-10-07, so 100 ms passes the calm day and fails
      // the stall days. event_loop_p99_ms stays the ungated trend.
      { field: "event_loop_max_ms", tm99: 100, label: "Event-loop stall max" },
    ],
  },
} as const satisfies Readonly<Record<string, EventDef>>;

// ── Derived types ──

type Events = typeof EVENTS;
export type EventName = keyof Events;
export type ServerEventName = Extract<EventName, `server.${string}`>;

type FieldDefs<N extends EventName> = Events[N]["fields"];
type IsOptionalField<D> = D extends { optional: true } ? true : false;
type RequiredFieldKeys<N extends EventName> = {
  [K in keyof FieldDefs<N>]: IsOptionalField<FieldDefs<N>[K]> extends true ? never : K;
}[keyof FieldDefs<N>];
type OptionalFieldKeys<N extends EventName> = Exclude<keyof FieldDefs<N>, RequiredFieldKeys<N>>;
type Simplify<T> = { [K in keyof T]: T[K] };

/** Numeric field values of an event; `bool` fields take 0 or 1. */
export type EventFields<N extends EventName> = Simplify<
  { [K in RequiredFieldKeys<N>]: number } & { [K in OptionalFieldKeys<N>]?: number }
>;

type TagUses<N extends EventName> = Events[N] extends { tags: infer T } ? T : Record<never, never>;
type VocabularyValue<K extends TagKey> = (typeof TAGS)[K] extends {
  kind: "enum";
  values: readonly (infer V)[];
}
  ? V
  : (typeof TAGS)[K] extends { kind: "bucket"; buckets: readonly { name: infer B }[] }
    ? B
    : string;
type TagValueOf<K, U> = K extends TagKey
  ? U extends { values: readonly (infer V)[] }
    ? V
    : VocabularyValue<K>
  : never;
type RequiredTagKeys<T> = { [K in keyof T]: T[K] extends { required: true } ? K : never }[keyof T];

export type EventTags<N extends EventName> = Simplify<
  { [K in RequiredTagKeys<TagUses<N>>]: TagValueOf<K, TagUses<N>[K]> } & {
    [K in Exclude<keyof TagUses<N>, RequiredTagKeys<TagUses<N>>>]?: TagValueOf<K, TagUses<N>[K]>;
  }
>;

/** Untyped view for code that walks the catalog (ingest, review, generator, checks). */
export const EVENT_DEFS: Readonly<Record<string, EventDef>> = EVENTS;
export const TAG_DEFS: Readonly<Record<string, TagDef>> = TAGS;

export function fieldSpec(def: FieldDef): FieldSpec {
  return typeof def === "string" ? { unit: def } : def;
}

export function eventOrigin(name: string): TelemetryOrigin | undefined {
  if (name.startsWith("app.")) return "app";
  if (name.startsWith("server.")) return "server";
  return undefined;
}
