import { validateToolArguments } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import askExtension from "../plugins/ask/index.js";
import backgroundJobsExtension from "../plugins/background-jobs/index.js";
import subagentsExtension from "../plugins/subagents/index.js";
import { createSandboxGrepToolDefinition, type GondolinVm } from "../src/gondolin-ops.js";
import { LiveVoiceSpeech } from "../src/live-voice-speech.js";
import { createNotifyExtension } from "../src/session-notify-extension.js";

// Classic sessions and the Pi terminal share these entries, so their schemas must keep accepting
// what TypeBox's did: arguments they do not declare, but no value outside an enum.

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

function validate(schemas: Record<string, unknown>, name: string, args: unknown): unknown {
  const tool = { name, description: name, parameters: schemas[name] } as never;
  return validateToolArguments(tool, {
    type: "toolCall",
    id: "c1",
    name,
    arguments: args,
  } as never);
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

  it.each(Object.keys(CALLS))("Pi accepts a real %s call with an undeclared argument", (name) => {
    const args = { ...CALLS[name], unexpected: "kept" };
    expect(validate(schemas, name, args)).toEqual(args);
  });

  it("Pi rejects an action outside the enum", () => {
    expect(() => validate(schemas, "background_job", { action: "status" })).toThrow(
      /action: expected one of \["start","cancel"\]/,
    );
  });
});
