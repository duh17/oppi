import { describe, expect, it } from "vitest";

import { captureCliOutput, writeJsonEnvelope } from "../src/cli/output.js";
import { redactCredentialString, redactCredentialValue } from "../src/credential-redaction.js";

const secrets = {
  owner: "sk_owner-output-fixture-secret",
  pairing: "pt_pairing-output-fixture-secret",
  authDevice: "dt_auth-output-fixture-secret",
  accessToken: "at_access-output-fixture-secret",
  push: "apns-output-fixture-secret",
  liveActivity: "live-output-fixture-secret",
  runtime: "runtime-output-fixture-secret",
};

const credentialPayload = {
  token: secrets.owner,
  pairingToken: secrets.pairing,
  authDevices: [{ deviceId: "dev-output-fixture", token: secrets.authDevice }],
  authAccessTokens: [{ deviceId: "dev-output-fixture", token: secrets.accessToken }],
  pushDeviceTokens: [secrets.push],
  liveActivityToken: secrets.liveActivity,
  runtimeEnv: { OPENAI_API_KEY: secrets.runtime, TTS_BASE_URL: "http://127.0.0.1:7937" },
};

function expectNoFixtureCredentials(value: unknown): void {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  for (const secret of Object.values(secrets)) expect(text).not.toContain(secret);
}

describe("credential output redaction", () => {
  it("redacts credential-bearing values while preserving collection counts", () => {
    const redacted = redactCredentialValue(credentialPayload);
    const text = JSON.stringify(redacted);

    expectNoFixtureCredentials(redacted);
    expect(text).toContain("[REDACTED 1 device]");
    expect(text).toContain("[REDACTED 1 token]");
    expect(text).toContain('"TTS_BASE_URL":"http://127.0.0.1:7937"');
  });

  it("redacts bearer prefixes and authorization values embedded in text", () => {
    const input = `owner=${secrets.owner} pair=${secrets.pairing} device=${secrets.authDevice} Authorization: Bearer ${secrets.accessToken}`;
    const output = redactCredentialString(input);

    expectNoFixtureCredentials(output);
    expect(output).toContain("Bearer [REDACTED]");
  });

  it("redacts credential keys in persisted pretty-printed text", () => {
    const output = redactCredentialString(
      [
        "{",
        `  "deviceId": "dev-output-fixture",`,
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
        authDevices: "[REDACTED 1 device]",
        authAccessTokens: "[REDACTED 1 token]",
      },
    });
  });

});
