export const OPPI_MIRROR_BRIDGE_PROTOCOL_VERSION = 2;
export const OPPI_MIRROR_INPUT_PREFLIGHT_CAPABILITY = "input_preflight:v1";
export const OPPI_MIRROR_QUEUE_VERSION_MISMATCH_CODE = "queue_version_mismatch";
export const OPPI_MIRROR_QUEUE_VERSION_EXHAUSTED_CODE =
  "queue_version_exhausted";
export const OPPI_MIRROR_QUEUE_VERSION_INVALID_ERROR =
  "Queue version must be a nonnegative safe integer";
export const OPPI_MIRROR_QUEUE_VERSION_EXHAUSTED_ERROR = `Queue version exhausted at ${Number.MAX_SAFE_INTEGER}; start a new session to reset the queue counter`;

export function isOppiMirrorQueueVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function assertOppiMirrorQueueVersion(
  value: unknown,
): asserts value is number {
  if (!isOppiMirrorQueueVersion(value)) {
    throw new Error(OPPI_MIRROR_QUEUE_VERSION_INVALID_ERROR);
  }
}

/** Never wrap: a repeated version could make a pre-rollover stale CAS current again. */
export function nextOppiMirrorQueueVersion(value: unknown): number {
  assertOppiMirrorQueueVersion(value);
  if (value === Number.MAX_SAFE_INTEGER) {
    throw new Error(OPPI_MIRROR_QUEUE_VERSION_EXHAUSTED_ERROR);
  }
  return value + 1;
}

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
  OPPI_MIRROR_INPUT_PREFLIGHT_CAPABILITY,
] as const;

const BRIDGE_COMMAND_SET = new Set<string>(OPPI_MIRROR_BRIDGE_COMMANDS);

export function isOppiMirrorBridgeCommand(
  commandType: unknown,
): commandType is OppiMirrorBridgeCommand {
  return typeof commandType === "string" && BRIDGE_COMMAND_SET.has(commandType);
}
