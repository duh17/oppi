export const PI_TUI_MIRROR_REMOTE_COMMANDS = [
  "get_state",
  "get_messages",
  "get_fork_messages",
  "get_session_tree",
  "navigate_tree",
  "get_session_stats",
  "get_commands",
  "set_model",
  "cycle_model",
  "get_available_models",
  "set_thinking_level",
  "cycle_thinking_level",
  "set_session_name",
  "compact",
  "set_auto_compaction",
  "set_steering_mode",
  "set_follow_up_mode",
  "set_auto_retry",
  "abort_retry",
  "abort_bash",
  "abort",
  "reload",
  "get_queue",
  "set_queue",
] as const;

export type PiTuiMirrorRemoteCommand = (typeof PI_TUI_MIRROR_REMOTE_COMMANDS)[number];

export const PI_TUI_MIRROR_UNSUPPORTED_REMOTE_COMMAND_REASONS = {
  share_session: "sharing needs a server-owned AgentSession export path",
  new_session: "session replacement is terminal-owned; start it from the terminal",
  fork: "session-file replacement is terminal-owned; fork from the terminal",
  switch_session: "session-file replacement is terminal-owned; switch from the terminal",
} as const;

const REMOTE_COMMAND_SET = new Set<string>(PI_TUI_MIRROR_REMOTE_COMMANDS);
const UNSUPPORTED_REMOTE_COMMAND_REASON_MAP = new Map<string, string>(
  Object.entries(PI_TUI_MIRROR_UNSUPPORTED_REMOTE_COMMAND_REASONS),
);

export function isPiTuiMirrorRemoteCommand(
  commandType: string,
): commandType is PiTuiMirrorRemoteCommand {
  return REMOTE_COMMAND_SET.has(commandType);
}

export function piTuiMirrorUnsupportedRemoteCommandReason(commandType: string): string | undefined {
  return UNSUPPORTED_REMOTE_COMMAND_REASON_MAP.get(commandType);
}
