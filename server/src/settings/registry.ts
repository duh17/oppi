/**
 * The one table of every setting the server owns: scope, storage, default, validation, and
 * whether writes carry a revision. Routes and stores validate through these definitions, and
 * `protocol/settings.json` is the hand-maintained copy for the clients; the server test
 * `settings-registry.test.ts` keeps the two in step. No client test reads it yet.
 *
 * An entry exists only for a setting that exists. Add the entry and the fixture row together.
 */
import { hostMountValidationError } from "../host.js";
import { DEFAULT_ICON_CHOICE, validateIconChoice } from "../icon-choice.js";
import { parsePushEvents } from "../push/events.js";
import { validateDictionaryPhrases } from "../storage/dictation-dictionary-store.js";
import type { IconChoice, PushEvent, WorkspaceSandboxConfig } from "../types.js";
import { isRecord } from "../json-shape.js";

/** A write the setting refuses. Routes answer 400 with the message. */
export class SettingValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SettingValidationError";
  }
}

export type SettingScope = "server" | "workspace" | "device";
export type SettingStorage = "config" | "settings-file" | "workspace" | "pi" | "push-registration";

export interface ServerSettingDefinition<T> {
  readonly key: string;
  readonly scope: SettingScope;
  readonly storage: SettingStorage;
  /** `null` when there is no value to default to: derived at create time, or required. */
  readonly default: T | null;
  /** Writes may carry `baseRevision`; a stale one is a 409 `revision_conflict`. */
  readonly revisioned: boolean;
  /** Returns the value to store, or throws `SettingValidationError`. */
  validate(value: unknown): T;
}

/** A config-stored on/off setting's write: Server Metrics, Durable Sessions, Mobile Output Guide. */
export interface EnabledPatch {
  enabled: boolean;
}

export type WorkspaceWriteKind = "create" | "update";

function fail(message: string): never {
  throw new SettingValidationError(message);
}

/** Runs a validator that throws a plain `Error`, reporting its message as a validation error. */
function asSettingError<T>(validate: () => T): T {
  try {
    return validate();
  } catch (error) {
    if (error instanceof SettingValidationError) throw error;
    return fail(error instanceof Error ? error.message : String(error));
  }
}

function validateEnabledPatch(value: unknown): EnabledPatch {
  if (!isRecord(value) || typeof value.enabled !== "boolean") {
    return fail("enabled must be a boolean");
  }
  return { enabled: value.enabled };
}

function validatePiDefaultTools(value: unknown): string[] | null {
  if (value === null) return null;
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    return fail("defaultTools must be null or an array of strings");
  }
  return [...value];
}

function validatePiDefaultModel(value: unknown): string {
  if (typeof value !== "string") return fail("model must be a string");
  return value;
}

/** A phone's registration lists the events it wants; names this server does not send are dropped. */
function validatePushEvents(value: unknown): PushEvent[] {
  return parsePushEvents(value) ?? fail("events must be an array of strings");
}

/** Omitted means off. */
function validatePushLiveActivity(value: unknown): boolean {
  if (value === undefined) return false;
  if (typeof value !== "boolean") return fail("liveActivity must be a boolean");
  return value;
}

// ─── Workspace fields ───

/** The fields a Workspace write may carry. */
const WORKSPACE_WRITE_FIELDS: ReadonlySet<string> = new Set([
  "name",
  "description",
  "icon",
  "systemPrompt",
  "systemPromptMode",
  "hostMount",
  "tools",
  "gitStatusEnabled",
  "runtime",
  "sandboxConfig",
]);
const SANDBOX_CONFIG_FIELDS = ["allowedHosts", "env", "mcpServers", "hostExtensions"];
/** Pi server names: letters, digits, `_` and `-`. */
export const MCP_SERVER_NAME = /^[A-Za-z0-9_-]+$/;
/** An extension's server resource ID (`serverResourceId("extension", path)`). */
export const EXTENSION_ID = /^extension_[0-9a-f]{64}$/;

/** `null` clears a field on update; a create has nothing to clear. */
const clearable = (value: unknown, kind: WorkspaceWriteKind): boolean =>
  kind === "update" && value === null;

function optionalText(field: "description" | "systemPrompt") {
  return (value: unknown, kind: WorkspaceWriteKind = "update"): string | null => {
    if (typeof value === "string") return value;
    if (clearable(value, kind)) return null;
    return fail(`${field} must be a string${kind === "update" ? " or null" : ""}`);
  };
}

const validateWorkspaceName = (value: unknown): string => {
  if (typeof value !== "string" || value === "") return fail("name must be a non-empty string");
  return value;
};

function validateWorkspaceTools(
  value: unknown,
  kind: WorkspaceWriteKind = "update",
): string[] | null {
  if (clearable(value, kind)) return null;
  if (
    !Array.isArray(value) ||
    value.some((tool) => typeof tool !== "string" || tool === "" || tool !== tool.trim())
  ) {
    return fail(
      `tools must be an array of non-empty, trimmed strings${kind === "update" ? " or null" : ""}`,
    );
  }
  return [...value];
}

function validateWorkspaceGitStatusEnabled(value: unknown): boolean {
  if (typeof value !== "boolean") return fail("gitStatusEnabled must be true or false");
  return value;
}

function validateWorkspaceRuntime(value: unknown): "host" | "sandbox" {
  if (value !== "host" && value !== "sandbox") return fail('runtime must be "host" or "sandbox"');
  return value;
}

/**
 * A sandbox config exactly as sent; anything it cannot keep as sent is an error. An empty one
 * is none. `null` clears it on update.
 */
export function parseSandboxConfig(
  raw: unknown,
  kind: WorkspaceWriteKind = "update",
): WorkspaceSandboxConfig | undefined | null {
  if (clearable(raw, kind)) return null;
  if (!isRecord(raw)) return fail("sandboxConfig must be an object");
  for (const key of Object.keys(raw)) {
    if (!SANDBOX_CONFIG_FIELDS.includes(key)) {
      return fail(
        `Unknown sandboxConfig field ${JSON.stringify(key)}; it takes ${SANDBOX_CONFIG_FIELDS.join(", ")}`,
      );
    }
  }
  const result: WorkspaceSandboxConfig = {};
  const { allowedHosts, env, mcpServers, hostExtensions } = raw;
  if (allowedHosts !== undefined) {
    if (!Array.isArray(allowedHosts) || allowedHosts.some((host) => typeof host !== "string")) {
      return fail("sandboxConfig.allowedHosts must be an array of strings");
    }
    result.allowedHosts = [...allowedHosts];
  }
  if (env !== undefined) {
    if (!isRecord(env) || Object.values(env).some((entry) => typeof entry !== "string")) {
      return fail("sandboxConfig.env must be an object of string values");
    }
    result.env = { ...(env as Record<string, string>) };
  }
  if (mcpServers !== undefined) {
    if (
      !Array.isArray(mcpServers) ||
      mcpServers.some((name) => typeof name !== "string" || !MCP_SERVER_NAME.test(name))
    ) {
      return fail(
        "sandboxConfig.mcpServers must be an array of server names made of letters, digits, _ and -",
      );
    }
    result.mcpServers = [...mcpServers];
  }
  if (hostExtensions !== undefined) {
    if (
      !Array.isArray(hostExtensions) ||
      hostExtensions.some((id) => typeof id !== "string" || !EXTENSION_ID.test(id))
    ) {
      return fail(
        "sandboxConfig.hostExtensions must be an array of extension IDs (extension_<64 hex>, as `oppi extensions list --json` shows them)",
      );
    }
    result.hostExtensions = [...(hostExtensions as string[])];
  }
  return Object.keys(result).length > 0 ? result : undefined;
}

/** `undefined` means the request did not carry the field. */
function systemPromptModeValidationError(mode: unknown): string | undefined {
  if (mode === undefined) return undefined;
  if (mode !== "append") return "systemPromptMode must be append";
  return undefined;
}

/**
 * A Workspace write is stored as it is sent or refused with the reason: a field the Workspace
 * does not have, or a value it cannot keep as sent, never turns into a different Workspace than
 * the one the owner approved. Checks the fields the store itself judges; the folder's existence,
 * the prompt mode, and the icon's asset have their own checks at the route and store.
 */
export function validateWorkspaceWrite(input: object, kind: WorkspaceWriteKind): void {
  for (const key of Object.keys(input)) {
    if (!WORKSPACE_WRITE_FIELDS.has(key)) fail(`Unknown Workspace field ${JSON.stringify(key)}`);
  }
  const { name, description, systemPrompt, gitStatusEnabled, tools, runtime, sandboxConfig } =
    input as Record<string, unknown>;
  if (name !== undefined) validateWorkspaceName(name);
  if (description !== undefined) optionalText("description")(description, kind);
  if (systemPrompt !== undefined) optionalText("systemPrompt")(systemPrompt, kind);
  if (gitStatusEnabled !== undefined) validateWorkspaceGitStatusEnabled(gitStatusEnabled);
  if (tools !== undefined) validateWorkspaceTools(tools, kind);
  if (runtime !== undefined) validateWorkspaceRuntime(runtime);
  if (sandboxConfig !== undefined) parseSandboxConfig(sandboxConfig, kind);
}

// ─── The table ───

const SETTINGS = {
  serverMetrics: {
    scope: "server",
    storage: "config",
    default: { enabled: false } as EnabledPatch,
    revisioned: true,
    validate: validateEnabledPatch,
  },
  durableSessions: {
    scope: "server",
    storage: "config",
    default: { enabled: false } as EnabledPatch,
    revisioned: true,
    validate: validateEnabledPatch,
  },
  mobileOutputGuide: {
    scope: "server",
    storage: "config",
    default: { enabled: false } as EnabledPatch,
    revisioned: true,
    validate: validateEnabledPatch,
  },
  dictionaryGlobal: {
    scope: "server",
    storage: "settings-file",
    default: [] as string[],
    revisioned: true,
    validate: (value: unknown) => asSettingError(() => validateDictionaryPhrases(value)),
  },
  dictionaryWorkspace: {
    scope: "workspace",
    storage: "settings-file",
    default: [] as string[],
    revisioned: true,
    validate: (value: unknown) => asSettingError(() => validateDictionaryPhrases(value)),
  },
  piDefaultTools: {
    scope: "server",
    storage: "pi",
    default: null,
    revisioned: false,
    validate: validatePiDefaultTools,
  },
  piDefaultModel: {
    scope: "server",
    storage: "pi",
    default: null,
    revisioned: false,
    validate: validatePiDefaultModel,
  },
  pushEvents: {
    scope: "device",
    storage: "push-registration",
    default: null,
    revisioned: false,
    validate: validatePushEvents,
  },
  pushLiveActivity: {
    scope: "device",
    storage: "push-registration",
    default: false,
    revisioned: false,
    validate: validatePushLiveActivity,
  },
  "workspace.name": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: validateWorkspaceName,
  },
  "workspace.description": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: (value: unknown) => optionalText("description")(value),
  },
  "workspace.icon": {
    scope: "workspace",
    storage: "workspace",
    default: DEFAULT_ICON_CHOICE as IconChoice,
    revisioned: false,
    // The store also checks that a genmoji's asset exists.
    validate: (value: unknown) => asSettingError(() => validateIconChoice(value)),
  },
  "workspace.systemPrompt": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: (value: unknown) => optionalText("systemPrompt")(value),
  },
  "workspace.systemPromptMode": {
    scope: "workspace",
    storage: "workspace",
    default: "append",
    revisioned: false,
    validate: (value: unknown) => {
      const error = systemPromptModeValidationError(value);
      if (error) return fail(error);
      return value as "append" | undefined;
    },
  },
  "workspace.hostMount": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: (value: unknown) => {
      const error = hostMountValidationError(value);
      if (error) return fail(error);
      return value as string | null | undefined;
    },
  },
  "workspace.tools": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: (value: unknown) => validateWorkspaceTools(value),
  },
  "workspace.gitStatusEnabled": {
    scope: "workspace",
    storage: "workspace",
    default: true,
    revisioned: false,
    validate: validateWorkspaceGitStatusEnabled,
  },
  "workspace.runtime": {
    scope: "workspace",
    storage: "workspace",
    default: "host",
    revisioned: false,
    validate: validateWorkspaceRuntime,
  },
  "workspace.sandboxConfig": {
    scope: "workspace",
    storage: "workspace",
    default: null,
    revisioned: false,
    validate: (value: unknown) => parseSandboxConfig(value),
  },
} satisfies Record<
  string,
  Omit<ServerSettingDefinition<unknown>, "key" | "validate"> & {
    validate(value: unknown): unknown;
  }
>;

export type SettingKey = keyof typeof SETTINGS;
type SettingValue<K extends SettingKey> = ReturnType<(typeof SETTINGS)[K]["validate"]>;

export const SERVER_SETTING_DEFINITIONS: readonly ServerSettingDefinition<unknown>[] =
  Object.entries(SETTINGS).map(([key, definition]) => ({ key, ...definition }));

export function settingDefinition<K extends SettingKey>(
  key: K,
): ServerSettingDefinition<SettingValue<K>> {
  return SERVER_SETTING_DEFINITIONS.find(
    (definition) => definition.key === key,
  ) as ServerSettingDefinition<SettingValue<K>>;
}

/** The value a write to `key` stores; throws `SettingValidationError` for one it refuses. */
export function validateSetting<K extends SettingKey>(key: K, value: unknown): SettingValue<K> {
  return settingDefinition(key).validate(value);
}
