#!/usr/bin/env node
/**
 * Paired E2E harness approver.
 *
 * The harness pairs a bootstrap device (e2e-precreate-pair.mjs) before the app,
 * so the app's invite, which outlives SHORT_INVITE_MAX_TTL_MS to survive a cold
 * build, waits for an approval from an already-paired device. This process is
 * that device: it polls GET /auth/pairing-approvals and approves each request
 * with a P-256 signature through the real API, refreshing its access token with
 * the same key when it expires. It runs until its parent exits or it is killed.
 *
 * Env: E2E_BASE_URL, E2E_BOOTSTRAP_CREDENTIAL_FILE (from e2e-precreate-pair.mjs).
 */
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const POLL_MS = 500;

/** Matches pairingApprovalMessage in src/device-pairing.ts. */
export function approvalSignature(privateKey, approvalId, keyThumbprint) {
  return signDeviceMessage(privateKey, `oppi:pair-approve:v1.${approvalId}.${keyThumbprint}`);
}

/** Matches the REFRESH_AUDIENCE signature in src/storage/device-auth.ts. */
export function refreshSignature(privateKey, nonce) {
  return signDeviceMessage(privateKey, `oppi:refresh:v1.${nonce}`);
}

function signDeviceMessage(privateKey, message) {
  return sign("sha256", Buffer.from(message, "utf8"), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
}

class FatalError extends Error {}

export function createApprover({ baseURL, credential, log = console.log }) {
  const base = baseURL.replace(/\/$/, "");
  const privateKey = createPrivateKey({ key: credential.privateKey, format: "jwk" });
  let accessToken = credential.accessToken;
  const settled = new Set();

  async function post(path, body, token) {
    return fetch(`${base}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
  }

  async function refreshAccessToken() {
    const challenge = await post("/auth/challenge", { deviceId: credential.deviceId });
    if (!challenge.ok) {
      throw new FatalError(
        `challenge failed: status=${challenge.status} body=${await challenge.text()}`,
      );
    }
    const { nonce } = await challenge.json();
    const refreshed = await post("/auth/refresh", {
      deviceId: credential.deviceId,
      nonce,
      signature: refreshSignature(privateKey, nonce),
    });
    if (!refreshed.ok) {
      throw new FatalError(
        `refresh failed: status=${refreshed.status} body=${await refreshed.text()}`,
      );
    }
    accessToken = (await refreshed.json()).accessToken;
    log("[e2e-approver] refreshed access token");
  }

  async function listApprovals() {
    const get = () =>
      fetch(`${base}/auth/pairing-approvals`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
    let response = await get();
    if (response.status === 401) {
      await refreshAccessToken();
      response = await get();
    }
    if (!response.ok) {
      throw new FatalError(`list failed: status=${response.status} body=${await response.text()}`);
    }
    return (await response.json()).approvals ?? [];
  }

  /** One poll: approve every pending request not yet settled. Returns approved ids. */
  async function approvePending() {
    const approved = [];
    for (const approval of await listApprovals()) {
      if (settled.has(approval.id)) continue;
      const response = await post(
        `/auth/pairing-approvals/${encodeURIComponent(approval.id)}/approve`,
        { signature: approvalSignature(privateKey, approval.id, approval.keyThumbprint) },
        accessToken,
      );
      const text = await response.text();
      if (response.ok) {
        settled.add(approval.id);
        approved.push(approval.id);
        log(`[e2e-approver] approved ${approval.id} device=${JSON.stringify(approval.deviceName)}`);
      } else if (response.status === 404) {
        // Expired or settled elsewhere between list and approve.
        settled.add(approval.id);
        log(`[e2e-approver] approval ${approval.id} is gone: body=${text}`);
      } else if (text.includes("bad_signature")) {
        throw new FatalError(`approve ${approval.id} rejected the signature: body=${text}`);
      } else {
        // An access token that expired since the list call: the next poll refreshes and retries.
        log(`[e2e-approver] approve ${approval.id} failed: status=${response.status} body=${text}`);
      }
    }
    return approved;
  }

  return { approvePending };
}

async function main() {
  const baseURL = process.env.E2E_BASE_URL?.trim();
  const credentialFile = process.env.E2E_BOOTSTRAP_CREDENTIAL_FILE?.trim();
  if (!baseURL || !credentialFile) {
    console.error("[e2e-approver] E2E_BASE_URL and E2E_BOOTSTRAP_CREDENTIAL_FILE are required");
    process.exit(1);
  }
  const credential = JSON.parse(readFileSync(credentialFile, "utf8"));
  const approver = createApprover({ baseURL, credential });
  // A SIGKILLed harness skips its cleanup; reparenting means nobody needs approvals anymore.
  const parent = process.ppid;
  console.log(`[e2e-approver] approving pairings on ${baseURL} as device ${credential.deviceId}`);
  let lastError = "";
  while (process.ppid === parent) {
    try {
      await approver.approvePending();
      lastError = "";
    } catch (error) {
      if (error instanceof FatalError) {
        console.error(`[e2e-approver] ${error.message}`);
        process.exit(1);
      }
      // The server can be briefly unreachable (restart tests); log each new failure once.
      const message = error instanceof Error ? error.message : String(error);
      if (message !== lastError) console.error(`[e2e-approver] poll failed: ${message}`);
      lastError = message;
    }
    await new Promise((done) => setTimeout(done, POLL_MS));
  }
  console.log("[e2e-approver] parent exited; stopping");
}

const isMain =
  process.argv[1] != null && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) {
  await main();
}
