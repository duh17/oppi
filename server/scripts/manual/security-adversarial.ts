#!/usr/bin/env npx tsx
/**
 * Adversarial pairing checks for one-time pairing tokens.
 *
 * Usage:
 *   cd server
 *   npx tsx scripts/manual/security-adversarial.ts
 */

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Storage } from "../../src/storage.js";

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

async function main(): Promise<void> {
  const tempDir = mkdtempSync(join(tmpdir(), "oppi-server-security-e2e-"));
  const storage = new Storage(tempDir);

  try {
    console.log("\n━━━ Adversarial pairing checks ━━━\n");

    const pairingToken = storage.issuePairingToken(60_000);
    check("issued pairing token has pt_ prefix", pairingToken.startsWith("pt_"));

    const firstDeviceToken = storage.consumePairingToken(pairingToken);
    check(
      "valid pairing token issues auth device token",
      firstDeviceToken !== null && firstDeviceToken.startsWith("dt_"),
    );

    const replayToken = storage.consumePairingToken(pairingToken);
    check("replay pairing token is rejected", replayToken === null);

    const shortLived = storage.issuePairingToken(1_000);
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    const expired = storage.consumePairingToken(shortLived);
    check("expired pairing token is rejected", expired === null);

    const wrong = storage.consumePairingToken("pt_not_the_real_token");
    check("invalid pairing token is rejected", wrong === null);

    console.log(`\nResult: ${passed} passed, ${failed} failed`);
    if (failed > 0) {
      process.exitCode = 1;
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

await main();
