#!/usr/bin/env node
/**
 * Official Apple e2e.sh pre-create pairing.
 *
 * POST /pair with a one-time pairing token and a P-256 device public key.
 * Prints the short-lived accessToken on success. On non-200, prints HTTP
 * status and response body to stderr so the failure is not swallowed.
 *
 * With E2E_BOOTSTRAP_CREDENTIAL_FILE set, also writes the enrolled device id,
 * access token, and private key there (mode 0600) so e2e-pairing-approver.mjs
 * can approve the app's pairing as this already-paired device.
 */
import { generateKeyPairSync } from "node:crypto";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function makeDeviceKeyPair() {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  if (!jwk.x || !jwk.y) {
    throw new Error("failed to export P-256 public key");
  }
  return {
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    privateKey: privateKey.export({ format: "jwk" }),
  };
}

export function pairRequestBody(
  pairingToken,
  devicePublicKey,
  deviceName = "e2e-script-bootstrap",
) {
  return { pairingToken, deviceName, devicePublicKey };
}

export function interpretPairResponse(status, text) {
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  const accessToken = json && typeof json.accessToken === "string" ? json.accessToken : "";
  const deviceId = json && typeof json.deviceId === "string" ? json.deviceId : "";
  if (status !== 200 || !accessToken || !deviceId) {
    return { ok: false, error: `status=${status} body=${text}` };
  }
  return { ok: true, accessToken, deviceId };
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
  const keyPair = makeDeviceKeyPair();
  const response = await fetch(`${baseURL}/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(pairRequestBody(opts.pairingToken, keyPair.publicKey, opts.deviceName)),
  });
  const text = await response.text();
  const result = interpretPairResponse(response.status, text);
  return result.ok ? { ...result, privateKey: keyPair.privateKey } : result;
}

async function main() {
  const baseURL = requiredEnv("E2E_BASE_URL");
  const pairingToken = requiredEnv("PAIRING_TOKEN");
  const deviceName = process.env.E2E_DEVICE_NAME?.trim() || "e2e-script-bootstrap";
  const credentialFile = process.env.E2E_BOOTSTRAP_CREDENTIAL_FILE?.trim();
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
  if (credentialFile) {
    const { deviceId, accessToken, privateKey } = result;
    writeFileSync(credentialFile, JSON.stringify({ deviceId, accessToken, privateKey }), {
      mode: 0o600,
    });
  }
  console.log(result.accessToken);
}

const isMain =
  process.argv[1] != null && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) {
  await main();
}
