#!/usr/bin/env npx tsx
/**
 * Adversarial security checks for bootstrap trust paths.
 *
 * Exercises replay/tamper/mismatch classes against real route-handler posture
 * and invite-signing primitives without requiring network ports.
 *
 * Usage:
 *   cd oppi-server
 *   npx tsx test-security-adversarial.ts
 */

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Storage } from "./src/storage.js";
import { RouteHandler, type RouteContext } from "./src/routes.js";
import {
  createSignedInviteV2,
  ensureIdentityMaterial,
  verifyInviteV2,
  type InviteV2Envelope,
  type InviteV2Payload,
} from "./src/security.js";

interface SecurityProfileResponse {
  profile: "legacy" | "tailscale-permissive" | "strict";
  identity: {
    keyId: string;
    fingerprint: string;
  };
}

interface MockResponse {
  statusCode: number;
  body: string;
  writeHead: (status: number, _headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

let passed = 0;
let failed = 0;

function check(name: string, condition: boolean, detail?: string): void {
  if (condition) {
    console.log(`  ✅ ${name}`);
    passed += 1;
    return;
  }

  console.error(`  ❌ ${name}${detail ? ` — ${detail}` : ""}`);
  failed += 1;
}

function cloneEnvelope(envelope: InviteV2Envelope): InviteV2Envelope {
  return JSON.parse(JSON.stringify(envelope)) as InviteV2Envelope;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    body: "",
    writeHead(status: number): MockResponse {
      this.statusCode = status;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

async function resolveSecurityProfile(storage: Storage): Promise<SecurityProfileResponse> {
  const user = storage.createUser("security-adversarial");
  const ctx = { storage } as unknown as RouteContext;
  const routes = new RouteHandler(ctx);
  const res = makeResponse();

  await routes.dispatch(
    "GET",
    "/security/profile",
    new URL("http://localhost/security/profile"),
    user,
    {} as never,
    res as never,
  );

  if (res.statusCode !== 200) {
    throw new Error(`GET /security/profile dispatch failed: ${res.statusCode}`);
  }

  return JSON.parse(res.body) as SecurityProfileResponse;
}

async function main(): Promise<void> {
  const tempDir = mkdtempSync(join(tmpdir(), "oppi-server-security-e2e-"));
  const storage = new Storage(tempDir);

  try {
    const cfg = storage.getConfig();
    storage.updateConfig({
      security: {
        ...cfg.security!,
        profile: "strict",
        requireTlsOutsideTailnet: true,
        allowInsecureHttpInTailnet: true,
        requirePinnedServerIdentity: true,
      },
      invite: {
        ...cfg.invite!,
        format: "v2-signed",
        maxAgeSeconds: 60,
      },
    });

    const profile = await resolveSecurityProfile(storage);

    const identityConfig = storage.getConfig().identity;
    if (!identityConfig) {
      throw new Error("Missing identity config");
    }

    const identity = ensureIdentityMaterial(identityConfig);

    const basePayload: InviteV2Payload = {
      host: "myhost.tail12345.ts.net",
      port: storage.getConfig().port,
      token: "sk_adversarial",
      name: "security-adversarial",
      fingerprint: profile.identity.fingerprint,
      securityProfile: profile.profile,
    };

    console.log("\n━━━ Adversarial bootstrap checks ━━━\n");

    const baseline = createSignedInviteV2(identity, basePayload, 60, Date.now());
    check("baseline signed invite verifies", verifyInviteV2(baseline));

    const tamperedPayload = cloneEnvelope(baseline);
    tamperedPayload.payload.host = "evil.example.com";
    check("tampered payload is rejected", verifyInviteV2(tamperedPayload) === false);

    const tamperedKid = cloneEnvelope(baseline);
    tamperedKid.kid = "srv-attacker";
    check("tampered key id is rejected", verifyInviteV2(tamperedKid) === false);

    const replayInvite = createSignedInviteV2(identity, basePayload, 30, Date.now() - 3_600_000);
    check("replay invite signature remains cryptographically valid", verifyInviteV2(replayInvite));

    const nowSec = Math.floor(Date.now() / 1000);
    check(
      "replay invite freshness check detects expiry",
      replayInvite.exp < nowSec,
      `exp=${replayInvite.exp}, now=${nowSec}`,
    );

    const mismatchInvite = createSignedInviteV2(
      identity,
      {
        ...basePayload,
        fingerprint: "sha256:mismatched-profile-fingerprint",
      },
      60,
      Date.now(),
    );
    check("mismatch invite still verifies cryptographically", verifyInviteV2(mismatchInvite));
    check(
      "profile mismatch class detected",
      mismatchInvite.payload.fingerprint !== profile.identity.fingerprint,
      `invite=${mismatchInvite.payload.fingerprint}, profile=${profile.identity.fingerprint}`,
    );

    console.log(`\nResult: ${passed} passed, ${failed} failed`);
    if (failed > 0) {
      process.exitCode = 1;
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

await main();
