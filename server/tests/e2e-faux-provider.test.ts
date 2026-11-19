import {} from "node:fs";
import { join } from "node:path";

import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  E2E_FAUX_MODEL_ID,
  E2E_FAUX_PROVIDER_ID,
  e2eFauxReplyText,
  e2eFauxToolCalls,
  registerE2EFauxProvider,
} from "../src/e2e-faux-provider.js";
import { makeTempDir } from "./harness/temp-dir.js";

async function modelRuntime(): Promise<ModelRuntime> {
  const dir = makeTempDir("oppi-e2e-faux-");
  return ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
}

function prompt(text: string) {
  return { messages: [{ role: "user" as const, content: text, timestamp: Date.now() }] };
}

describe("E2E faux provider", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it.each([
    { harness: undefined, faux: "1" },
    { harness: "1", faux: undefined },
    { harness: "0", faux: "1" },
  ])("stays off unless both E2E gates are set: %o", async ({ harness, faux }) => {
    vi.stubEnv("OPPI_E2E_UI_HARNESS", harness);
    vi.stubEnv("OPPI_E2E_FAUX_PROVIDER", faux);
    const models = await modelRuntime();

    expect(await registerE2EFauxProvider(models)).toBe(false);
    expect(models.getRegisteredNativeProvider(E2E_FAUX_PROVIDER_ID)).toBeUndefined();
  });

  it("answers every request, including concurrent ones, with the scripted reply", async () => {
    vi.stubEnv("OPPI_E2E_UI_HARNESS", "1");
    vi.stubEnv("OPPI_E2E_FAUX_PROVIDER", "1");
    const models = await modelRuntime();
    expect(await registerE2EFauxProvider(models)).toBe(true);
    await models.refresh({ allowNetwork: false });

    const model = models.getModel(E2E_FAUX_PROVIDER_ID, E2E_FAUX_MODEL_ID);
    expect(model).toBeDefined();
    const replies = await Promise.all(
      ["first", "second", "third"].map((text) => models.completeSimple(model!, prompt(text))),
    );

    expect(replies.map((reply) => reply.stopReason)).toEqual(["stop", "stop", "stop"]);
    expect(replies.map((reply) => reply.content)).toEqual(
      ["first", "second", "third"].map((text) => [{ type: "text", text: e2eFauxReplyText(text) }]),
    );
  }, 60_000);

  it("calls a tool for a directive on the prompt's last line, and answers its result with text", async () => {
    vi.stubEnv("OPPI_E2E_UI_HARNESS", "1");
    vi.stubEnv("OPPI_E2E_FAUX_PROVIDER", "1");
    const models = await modelRuntime();
    expect(await registerE2EFauxProvider(models)).toBe(true);
    await models.refresh({ allowNetwork: false });
    const model = models.getModel(E2E_FAUX_PROVIDER_ID, E2E_FAUX_MODEL_ID)!;

    // A child's task arrives under a model-only header; the directive is its last line.
    const spawn = await models.completeSimple(
      model,
      prompt("faux:subagent kid faux:bash echo tick"),
    );
    expect(spawn.stopReason).toBe("toolUse");
    expect(spawn.content).toMatchObject([
      {
        type: "toolCall",
        name: "subagent",
        arguments: { action: "spawn", name: "kid", task: "faux:bash echo tick" },
      },
    ]);
    expect(e2eFauxToolCalls(prompt("faux:subagent-wait kid faux:bash echo tick").messages)).toEqual(
      [
        {
          name: "subagent",
          arguments: { action: "spawn", name: "kid", task: "faux:bash echo tick", wait: true },
        },
      ],
    );
    // Several children in one answer.
    expect(
      e2eFauxToolCalls(prompt("faux:subagents a Plan it. || b faux:bash sleep 9").messages),
    ).toEqual([
      { name: "subagent", arguments: { action: "spawn", name: "a", task: "Plan it." } },
      { name: "subagent", arguments: { action: "spawn", name: "b", task: "faux:bash sleep 9" } },
    ]);
    const child = await models.completeSimple(
      model,
      prompt("[From parent]\n\nfaux:bash echo tick"),
    );
    expect(child.content).toMatchObject([
      { type: "toolCall", name: "bash", arguments: { command: "echo tick" } },
    ]);

    // A one-line prompt hands over a multi-line brief whose last line the child acts on.
    expect(
      e2eFauxToolCalls(prompt("faux:subagent kid Read the brief.\\n\\nfaux:bash echo tick").messages),
    ).toEqual([
      {
        name: "subagent",
        arguments: { action: "spawn", name: "kid", task: "Read the brief.\n\nfaux:bash echo tick" },
      },
    ]);

    // A one-line prompt carries a multi-line script.
    expect(e2eFauxToolCalls(prompt("faux:codemode const a = 1;\\nreturn a;").messages)).toEqual([
      { name: "codemode", arguments: { code: "const a = 1;\nreturn a;" } },
    ]);

    // The tool's result is answered with text, and an echoed directive is not a call.
    expect(
      e2eFauxToolCalls([
        ...prompt("faux:bash echo tick").messages,
        {
          role: "toolResult",
          toolCallId: "c",
          toolName: "bash",
          content: [],
          isError: false,
          timestamp: 0,
        },
      ]),
    ).toEqual([]);
    expect(e2eFauxToolCalls(prompt(e2eFauxReplyText("faux:bash echo tick")).messages)).toEqual([]);

    // A child can ask the user, and fail the way a provider refuses a request.
    expect(
      e2eFauxToolCalls(prompt("[From parent]\n\nfaux:ask Land which first?").messages),
    ).toMatchObject([
      { name: "ask", arguments: { questions: [{ question: "Land which first?" }] } },
    ]);
    const failed = await models.completeSimple(model, prompt("faux:fail Bad request: refused"));
    expect(failed).toMatchObject({ stopReason: "error", errorMessage: "Bad request: refused" });
  }, 60_000);
});
