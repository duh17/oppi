import { describe, expect, it, vi } from "vitest";

const malformed = vi.hoisted(() => ({ envelope: {} as unknown }));

vi.mock("../src/cli/commands/agent.js", async () => {
  const { writeJsonEnvelope } = await import("../src/cli/output.js");
  return {
    cmdAgent: async () => writeJsonEnvelope(malformed.envelope as never),
  };
});

import { runCli } from "../src/cli/runner.js";

describe("canonical CLI runner envelope validation", () => {
  it.each([
    ["success without data", { ok: true }],
    ["failure without an error message", { ok: false, error: {} }],
  ])("fails closed for malformed %s envelopes", async (_name, envelope) => {
    malformed.envelope = envelope;

    const result = await runCli(["agent", "list"], {
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({
      ok: false,
      exitCode: 1,
      error: { message: "CLI command did not produce a valid JSON envelope" },
    });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      error: { message: "CLI command did not produce a valid JSON envelope" },
    });
    expect(result.humanOutput).toContain("\u001b[");
  });
});
