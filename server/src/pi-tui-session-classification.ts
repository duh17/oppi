import type { Session } from "./types.js";

const PI_AGENT_TASK_SESSION_NAME_RE = /^[A-Za-z][A-Za-z0-9_-]*#[0-9a-f]{8}$/i;

export interface PiTuiSessionLike {
  runtime?: Session["runtime"];
  name?: string;
  piSessionFile?: string;
  piSessionFiles?: string[];
  parentSessionId?: string;
}

export interface PiTuiBridgeStateLike {
  sessionName?: string;
  sessionFile?: string;
}

export function isPiTuiTaskRecordSession(session: PiTuiSessionLike): boolean {
  if (session.runtime !== "pi-tui") return false;
  if (session.parentSessionId) return false;
  if (hasTraceFile(session.piSessionFile, session.piSessionFiles)) return false;
  return isPiAgentTaskSessionName(session.name);
}

export function isPiTuiTaskRecordBridgeState(state: PiTuiBridgeStateLike): boolean {
  if (hasTraceFile(state.sessionFile)) return false;
  return isPiAgentTaskSessionName(state.sessionName);
}

function hasTraceFile(file?: string, files?: string[]): boolean {
  if (file?.trim()) return true;
  return files?.some((candidate) => candidate.trim().length > 0) ?? false;
}

function isPiAgentTaskSessionName(name: string | undefined): boolean {
  const trimmed = name?.trim();
  return !!trimmed && PI_AGENT_TASK_SESSION_NAME_RE.test(trimmed);
}
