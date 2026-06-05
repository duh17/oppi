export const OPPI_MIRROR_SERVER_REMOTE_COMMANDS = [
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

export const OPPI_MIRROR_TERMINAL_CONTROL_COMMANDS = [
  "prompt",
  "steer",
  "follow_up",
  "stop",
] as const;

export const OPPI_MIRROR_BRIDGE_COMMANDS = [
  ...OPPI_MIRROR_TERMINAL_CONTROL_COMMANDS,
  ...OPPI_MIRROR_SERVER_REMOTE_COMMANDS,
] as const;

export type OppiMirrorBridgeCommand =
  (typeof OPPI_MIRROR_BRIDGE_COMMANDS)[number];

export const OPPI_MIRROR_CAPABILITIES = [
  "prompt",
  "steer",
  "follow_up",
  "abort",
  "model",
  "thinking",
  "session_name",
  "compact",
  "queue",
  "tree_navigation",
  "runtime_modes",
  "retry",
  "bash_abort",
  "state",
  "extension_ui_proxy",
] as const;

const BRIDGE_COMMAND_SET = new Set<string>(OPPI_MIRROR_BRIDGE_COMMANDS);

export function isOppiMirrorBridgeCommand(
  commandType: unknown,
): commandType is OppiMirrorBridgeCommand {
  return typeof commandType === "string" && BRIDGE_COMMAND_SET.has(commandType);
}
