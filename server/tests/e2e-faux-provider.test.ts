import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  E2E_FAUX_MODEL_ID,
  E2E_FAUX_PROVIDER_ID,
  e2eFauxReplyText,
  registerE2EFauxProvider,
} from "../src/e2e-faux-provider.js";

async function modelRuntime(): Promise<ModelRuntime> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-e2e-faux-"));
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
});
