import type { Context } from "@earendil-works/chord/context";
import { defineTool, section, type ToolExecutionApi } from "@earendil-works/pi-durable";
import {
  arr,
  bool,
  int,
  lit,
  num,
  obj,
  oneOf,
  opt,
  str,
  union,
  type Optional,
  type Schema,
} from "@earendil-works/pi-schema";
import { defineExtension, defineFacet, Extensions, oppiHost, type OppiGodotHost } from "oppi/v1";
import type { GodotCommandResult, GodotProject } from "../../src/types.js";
import {
  formatCommandResult,
  formatGodotChoices,
  formatGodotStatus,
  formatLogPage,
  GODOT_DESCRIPTIONS,
  GODOT_EXTENSION,
  GODOT_GUIDELINES,
  GODOT_TOOL_NAMES,
  PROJECT_PARAMETER,
} from "./contract.js";

/** The longest side of a capture the model is shown, unless a call asks for another. */
const CAPTURE_MAX_SIZE = 1280;

const project = opt(str({ description: PROJECT_PARAMETER, maxLength: 128 }));
const fraction = num({ minimum: 0, maximum: 1 });
const point = obj({ x: fraction, y: fraction });
const ms = (description: string): Optional<Schema<number>> =>
  opt(num({ minimum: 0, maximum: 60_000, description }));
const step = union([
  obj({ kind: lit("tap"), at: point, holdMs: ms("How long the finger stays down; default 50") }),
  obj({
    kind: lit("drag"),
    from: point,
    to: point,
    durationMs: ms("How long the drag takes; default 250"),
  }),
  obj({
    kind: lit("key"),
    key: str({ description: "A key name: Space, Enter, Escape, Left, Right, Up, Down, A, F1" }),
    holdMs: ms("How long the key stays down; default 50"),
  }),
  obj({
    kind: lit("action"),
    action: str({ description: "An input action the project defines, such as jump" }),
    holdMs: ms("How long the action stays pressed; default 50"),
    strength: opt(num({ minimum: 0, maximum: 1 })),
  }),
  obj({ kind: lit("wait"), ms: num({ minimum: 0, maximum: 60_000 }) }),
]);

type Text = { type: "text"; text: string };
const text = (value: string): Text => ({ type: "text", text: value });
const failure = (value: string): { output: Text[]; isError: true } => ({
  output: [text(value)],
  isError: true,
});

/** The games host and the game a call means, or the text that says why there is none. */
async function target(
  ref: string | undefined,
  api: ToolExecutionApi,
  context: Context,
): Promise<{ games: OppiGodotHost; project: GodotProject } | { error: string; list?: true }> {
  const games = await oppiHost().godot(api, context);
  if (!games) return { error: "Godot is not available in this session." };
  const resolved = await games.resolve(ref);
  if ("project" in resolved) return { games, project: resolved.project };
  return {
    error: formatGodotChoices(resolved.error, resolved.projects),
    ...(ref ? {} : { list: true as const }),
  };
}

async function capture(
  games: OppiGodotHost,
  projectId: string,
  maxSize: number | undefined,
): Promise<{ result: GodotCommandResult; image?: { data: string; mimeType: string } }> {
  const result = await games.command(projectId, {
    command: { name: "capture", maxSize: maxSize ?? CAPTURE_MAX_SIZE },
  });
  const captureId = (result.output as { captureId?: unknown } | undefined)?.captureId;
  if (!result.ok || typeof captureId !== "string") return { result };
  const bytes = await games.captureBytes(projectId, captureId);
  if (!bytes) return { result };
  return {
    result,
    image: { data: Buffer.from(bytes.data).toString("base64"), mimeType: bytes.mimeType },
  };
}

function captureOutput(
  shot: Awaited<ReturnType<typeof capture>>,
  lead: string,
): { output: Array<Text | { type: "image"; data: string; mimeType: string }>; isError?: boolean } {
  if (!shot.image) {
    const why = shot.result.ok
      ? "the player answered but its image did not arrive"
      : formatCommandResult(shot.result);
    return failure(`${lead}No capture: ${why}`);
  }
  const output = shot.result.output as { width?: number; height?: number } | undefined;
  const size = output?.width && output.height ? ` (${output.width}x${output.height})` : "";
  return {
    output: [
      text(`${lead}Capture from ${shot.result.playerId ?? "the player"}${size}.`),
      { type: "image", ...shot.image },
    ],
  };
}

const godotStatus = defineTool({
  name: GODOT_TOOL_NAMES.status,
  description: GODOT_DESCRIPTIONS.status,
  parameters: obj({ project }),
  replay: "safe",
  async execute(args, api, context) {
    const found = await target(args.project, api, context);
    if ("error" in found)
      return found.list ? { output: [text(found.error)] } : failure(found.error);
    const detail = await found.games.detail(found.project.id);
    if (!detail) return failure(`No game ${found.project.id}.`);
    const errors =
      found.games
        .logs(detail.id, { since: Math.max(0, detail.logNext - 500), limit: 500, level: "error" })
        ?.entries.slice(-5) ?? [];
    return { output: [text(formatGodotStatus(detail, errors, Date.now()))] };
  },
});

const godotLogs = defineTool({
  name: GODOT_TOOL_NAMES.logs,
  description: GODOT_DESCRIPTIONS.logs,
  parameters: obj({
    project,
    since: opt(int({ minimum: 0, description: "Read entries after this one: a read's next" })),
    level: opt(oneOf(["debug", "info", "warn", "error"], { description: "The lowest level" })),
    limit: opt(int({ minimum: 1, maximum: 500, description: "Most entries; default 100" })),
  }),
  replay: "safe",
  async execute(args, api, context) {
    const found = await target(args.project, api, context);
    if ("error" in found) return failure(found.error);
    const page = found.games.logs(found.project.id, {
      ...(args.since !== undefined ? { since: args.since } : {}),
      ...(args.level ? { level: args.level } : {}),
      limit: args.limit ?? 100,
    });
    if (!page) return failure(`No game ${found.project.id} in this workspace.`);
    return { output: [text(formatLogPage(page))] };
  },
});

const godotCapture = defineTool({
  name: GODOT_TOOL_NAMES.capture,
  description: GODOT_DESCRIPTIONS.capture,
  parameters: obj({
    project,
    maxSize: opt(
      int({
        minimum: 64,
        maximum: 4096,
        description: `Longest side in pixels; default ${CAPTURE_MAX_SIZE}`,
      }),
    ),
  }),
  async execute(args, api, context) {
    const found = await target(args.project, api, context);
    if ("error" in found) return failure(found.error);
    return captureOutput(await capture(found.games, found.project.id, args.maxSize), "");
  },
});

const godotInput = defineTool({
  name: GODOT_TOOL_NAMES.input,
  description: GODOT_DESCRIPTIONS.input,
  parameters: obj({
    project,
    steps: arr(step, { minItems: 1, maxItems: 200 }),
    capture: opt(bool({ description: "Take a capture after the last step" })),
  }),
  async execute(args, api, context) {
    const found = await target(args.project, api, context);
    if ("error" in found) return failure(found.error);
    const result = await found.games.command(found.project.id, {
      command: { name: "input", steps: args.steps },
    });
    const done = formatCommandResult(result);
    if (!result.ok) return failure(done);
    if (!args.capture) return { output: [text(done)] };
    return captureOutput(await capture(found.games, found.project.id, undefined), `${done}\n`);
  },
});

const godotReload = defineTool({
  name: GODOT_TOOL_NAMES.reload,
  description: GODOT_DESCRIPTIONS.reload,
  parameters: obj({
    project,
    tier: opt(
      oneOf(["scripts", "scene", "restart"], {
        description: "scripts keeps state, scene restarts the scene; default: the player decides",
      }),
    ),
  }),
  async execute(args, api, context) {
    const found = await target(args.project, api, context);
    if ("error" in found) return failure(found.error);
    const result = await found.games.command(found.project.id, {
      command: { name: "reload", ...(args.tier ? { tier: args.tier } : {}) },
    });
    const done = formatCommandResult(result);
    return result.ok ? { output: [text(done)] } : failure(done);
  },
});

export const DurableGodot = defineExtension({
  name: GODOT_EXTENSION,
  runtimes: ["host", "sandbox"],
  tools: [godotStatus, godotLogs, godotCapture, godotInput, godotReload],
  sections: [section("godot-guidelines", () => GODOT_GUIDELINES.join("\n"))],
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableGodot));
