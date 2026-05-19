// ─── Local Sessions ───

/** A pi TUI session discovered on the host (not yet managed by oppi). */
export interface LocalSession {
  /** Absolute path to the JSONL file. */
  path: string;
  /** Pi session UUID from the JSONL header. */
  piSessionId: string;
  /** Working directory where the session was started. */
  cwd: string;
  /** User-defined display name (from /name command), if set. */
  name?: string;
  /** First user message preview. */
  firstMessage?: string;
  /** Last model used (provider/modelId format). */
  model?: string;
  /** Number of user+assistant messages. */
  messageCount: number;
  /** Session creation timestamp (ms). */
  createdAt: number;
  /** File last-modified timestamp (ms). */
  lastModified: number;
}
