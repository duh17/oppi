#!/usr/bin/env node
/**
 * Official Apple e2e.sh pre-create pairing.
 *
 * POST /pair with a one-time pairing token and a P-256 device public key.
 * Prints the short-lived accessToken on success. On non-200, prints HTTP
 * status and response body to stderr so the failure is not swallowed.
 */
import { generateKeyPairSync } from "node:crypto";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function makeDevicePublicKey() {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  if (!jwk.x || !jwk.y) {
    throw new Error("failed to export P-256 public key");
  }
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

export function pairRequestBody(pairingToken, deviceName = "e2e-script-bootstrap") {
  return {
    pairingToken,
    deviceName,
    devicePublicKey: makeDevicePublicKey(),
  };
}

export function interpretPairResponse(status, text) {
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  const accessToken = json && typeof json.accessToken === "string" ? json.accessToken : "";
  if (status !== 200 || !accessToken) {
    return { ok: false, error: `status=${status} body=${text}` };
  }
  return { ok: true, accessToken };
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    console.error(`[e2e] ${name} is required`);
    process.exit(1);
  }
  return value;
}

export async function precreatePair(opts) {
  const baseURL = opts.baseURL.replace(/\/$/, "");
  const response = await fetch(`${baseURL}/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(pairRequestBody(opts.pairingToken, opts.deviceName)),
  });
  const text = await response.text();
  return interpretPairResponse(response.status, text);
}

async function main() {
  const baseURL = requiredEnv("E2E_BASE_URL");
  const pairingToken = requiredEnv("PAIRING_TOKEN");
  const deviceName = process.env.E2E_DEVICE_NAME?.trim() || "e2e-script-bootstrap";
  let result;
  try {
    result = await precreatePair({ baseURL, pairingToken, deviceName });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[e2e] POST /pair failed: status=0 body=${message}`);
    process.exit(1);
  }
  if (!result.ok) {
    console.error(`[e2e] POST /pair failed: ${result.error}`);
    process.exit(1);
  }
  console.log(result.accessToken);
}

const isMain = process.argv[1] != null && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) {
  await main();
}
