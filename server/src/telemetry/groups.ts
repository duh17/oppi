/**
 * Review and dashboard groups: the sections `telemetry-review` and the
 * generated event tables sort catalog events into (`EventDef.group`).
 */

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
