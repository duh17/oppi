import { readFileSync } from "node:fs";
import { validateToolArguments } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import askExtension from "../plugins/ask/index.js";
import backgroundJobsExtension from "../plugins/background-jobs/index.js";
import subagentsExtension from "../plugins/subagents/index.js";
import { createSandboxGrepToolDefinition, type GondolinVm } from "../src/gondolin-ops.js";
import { LiveVoiceSpeech } from "../src/live-voice-speech.js";
import { createNotifyExtension } from "../src/session-notify-extension.js";

// The classic tools' parameters as TypeBox built them before they moved to pi-schema, recorded
// once from the TypeBox code. Classic sessions and the Pi terminal share these entries, so the
// model must see the same schema and Pi must accept the same calls.
const TYPEBOX_SCHEMAS = JSON.parse(
  readFileSync(new URL("./fixtures/classic-tool-schemas.typebox.json", import.meta.url), "utf8"),
) as Record<string, unknown>;

/** Every tool a classic factory registers, by name, from a Pi API that records `registerTool`. */
function registeredParameters(factory: (pi: never) => void): Record<string, unknown> {
  const tools: Record<string, unknown> = {};
  const pi: object = new Proxy(
    {},
    {
      get: (_target, key) => {
        if (key === "registerTool")
          return (tool: { name: string; parameters: unknown }) => {
            tools[tool.name] = tool.parameters;
          };
        if (key === "events") return pi;
        return () => undefined;
      },
    },
  );
  factory(pi as never);
  return tools;
}

function classicSchemas(): Record<string, unknown> {
  return {
    ...registeredParameters(askExtension),
    ...registeredParameters(backgroundJobsExtension),
    ...registeredParameters(subagentsExtension),
    ...registeredParameters(
      createNotifyExtension("s", { offersNotify: () => true } as never).factory,
    ),
    ...registeredParameters(new LiveVoiceSpeech({} as never).extension("s").factory),
    grep: createSandboxGrepToolDefinition({} as GondolinVm, "/work").parameters,
  };
}

/**
 * The same JSON Schema in either builder's spelling: an absent `additionalProperties` and `true`
 * both allow other properties; TypeBox's string enum also says `type: "string"`, and a union of
 * constants is the same as their `enum`.
 */
function normalized(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(normalized);
  if (typeof schema !== "object" || schema === null) return schema;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(schema)) out[key] = normalized(value);
  const anyOf = out.anyOf;
  if (Array.isArray(anyOf) && anyOf.every((branch) => branch && "const" in branch)) {
    delete out.anyOf;
    out.enum = anyOf.map((branch: { const: unknown }) => branch.const);
  }
  if (Array.isArray(out.enum)) delete out.type;
  if (out.additionalProperties === true) delete out.additionalProperties;
  return out;
}

/** A real call of each tool, with an argument the schema does not declare. */
const CALLS: Record<string, Record<string, unknown>> = {
  ask: {
    questions: [
      {
        id: "scope",
        question: "Which scope?",
        options: [
          { value: "small", label: "Small", hint: "extra" },
          { value: "full", label: "Full" },
        ],
        multiSelect: false,
      },
    ],
    allowCustom: true,
  },
  bash: { command: "echo ok", timeout: 5 },
  background_job: { action: "start", command: "sleep 1", timeout: 30 },
  subagent: {
    action: "launch",
    workspace: "oppi",
    prompt: "Review the diff",
    model: "anthropic/claude-haiku-5-5",
    supervise: true,
  },
  notify: { title: "Build done", body: "Read the report in the PR." },
  speak: { text: "One moment." },
  grep: { pattern: "TODO", path: "src", ignoreCase: true, limit: 10 },
};

describe("classic tool schemas on pi-schema", () => {
  const schemas = classicSchemas();

  it("registers every recorded classic tool", () => {
    expect(Object.keys(schemas).sort()).toEqual(Object.keys(TYPEBOX_SCHEMAS).sort());
  });

  it.each(Object.keys(TYPEBOX_SCHEMAS))("%s matches its TypeBox schema", (name) => {
    expect(normalized(schemas[name])).toEqual(normalized(TYPEBOX_SCHEMAS[name]));
  });

  it.each(Object.keys(CALLS))("Pi accepts a real %s call with an undeclared argument", (name) => {
    const args = { ...CALLS[name], unexpected: "kept" };
    const tool = { name, description: name, parameters: schemas[name] } as never;
    const call = { type: "toolCall", id: "c1", name, arguments: args } as never;
    expect(validateToolArguments(tool, call)).toEqual(args);
  });
});
