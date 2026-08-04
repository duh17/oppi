import { afterEach, describe, expect, it, vi } from "vitest";

import { captureCliOutput, writeJsonEnvelope } from "../src/cli/output.js";
import { runCli } from "../src/cli/runner.js";
import { createOppiToolExtensionFactory } from "../src/oppi-tool-extension.js";
import { redactCredentialString, redactCredentialValue } from "../src/credential-redaction.js";

vi.mock("../src/cli/runner.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/runner.js")>();
  return { ...actual, runCli: vi.fn() };
});

const canonicalRun = vi.mocked(runCli);

const secrets = {
  owner: "sk_owner-output-fixture-secret",
  pairing: "pt_pairing-output-fixture-secret",
  authDevice: "dt_auth-output-fixture-secret",
  irohDevice: "dt_iroh-output-fixture-secret",
  irohClient: "iroh-client-output-fixture-id",
  push: "apns-output-fixture-secret",
  liveActivity: "live-output-fixture-secret",
  runtime: "runtime-output-fixture-secret",
};

const credentialPayload = {
  token: secrets.owner,
  pairingToken: secrets.pairing,
  authDeviceTokens: [secrets.authDevice],
  irohDeviceTokenBindings: [
    {
      token: secrets.irohDevice,
      clientNodeId: secrets.irohClient,
      allowedTransports: ["http", "iroh"],
    },
  ],
  pushDeviceTokens: [secrets.push],
  liveActivityToken: secrets.liveActivity,
  runtimeEnv: { OPENAI_API_KEY: secrets.runtime, TTS_BASE_URL: "http://127.0.0.1:7937" },
};

function expectNoFixtureCredentials(value: unknown): void {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  for (const secret of Object.values(secrets)) expect(text).not.toContain(secret);
}

afterEach(() => {
  canonicalRun.mockReset();
});

describe("credential output redaction", () => {
  it("redacts credential-bearing values while preserving counts and transport metadata", () => {
    const redacted = redactCredentialValue(credentialPayload);
    const text = JSON.stringify(redacted);

    expectNoFixtureCredentials(redacted);
    expect(text).toContain("[REDACTED 1 token]");
    expect(text).toContain('"count":1');
    expect(text).toContain('"transports":["http","iroh"]');
    expect(text).toContain('"TTS_BASE_URL":"http://127.0.0.1:7937"');
  });

  it("redacts Oppi bearer prefixes and authorization values embedded in text", () => {
    const input = `owner=${secrets.owner} pair=${secrets.pairing} device=${secrets.authDevice} Authorization: Bearer ${secrets.irohDevice}`;
    const output = redactCredentialString(input);

    expectNoFixtureCredentials(output);
    expect(output).toContain("Bearer [REDACTED]");
  });

  it("redacts credential keys in persisted pretty-printed text", () => {
    const output = redactCredentialString(
      [
        "{",
        `  "clientNodeId": "${secrets.irohClient}",`,
        `  "pushDeviceTokens": ["${secrets.push}"],`,
        `  "liveActivityToken": "${secrets.liveActivity}",`,
        `  "OPENAI_API_KEY": "${secrets.runtime}"`,
        "}",
      ].join("\n"),
    );

    expectNoFixtureCredentials(output);
    expect(output.match(/\[REDACTED\]/g)?.length).toBe(4);
  });

  it("redacts standard JSON CLI envelopes before capture or serialization", async () => {
    const captured = await captureCliOutput(async () => {
      writeJsonEnvelope({ ok: true, data: credentialPayload });
    });

    expectNoFixtureCredentials(captured.stdout);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: true,
      data: {
        token: "[REDACTED]",
        authDeviceTokens: "[REDACTED 1 token]",
        irohDeviceTokenBindings: { count: 1, transports: ["http", "iroh"] },
      },
    });
  });

  it("keeps credential redaction at the thin wrapper output boundary", async () => {
    const redactedJson =
      JSON.stringify({ ok: true, data: redactCredentialValue(credentialPayload) }) + "\n";
    const redactedHuman = `\u001b[31m${redactCredentialString(JSON.stringify(credentialPayload))}\u001b[0m\n`;
    canonicalRun.mockResolvedValueOnce({
      ok: true,
      exitCode: 0,
      stdout: redactedJson,
      humanOutput: redactedHuman,
      json: JSON.parse(redactedJson),
    });

    const tools = new Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>();
    createOppiToolExtensionFactory({
      identity: "ordinary",
      callerSessionId: "caller",
      policySnapshot: { approvalPolicy: "confirmDestructiveOnly" },
    })({
      on: () => undefined,
      registerTool: (tool: { name: string; execute: (...args: unknown[]) => Promise<unknown> }) =>
        tools.set(tool.name, tool),
    } as never);

    const result = await tools
      .get("oppi")!
      .execute("call-redaction", { args: ["workspace", "list"] }, undefined, undefined, {
        hasUI: false,
        ui: {},
      });

    expectNoFixtureCredentials(result);
    expect(result).toMatchObject({
      content: [{ text: redactedJson }],
      details: {
        expandedText: `$ oppi workspace list\n\n${redactedHuman}`,
        presentationFormat: "terminal",
      },
    });
  });
});
