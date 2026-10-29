#!/usr/bin/env node
/**
 * Official Apple e2e.sh invite generator.
 *
 * Always emit a signed v3 HTTPS/HTTP pairing invite via generateInvite.
 */
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const [{ Storage }, { generateInvite }] = await Promise.all([
  import(pathToFileURL(join(serverRoot, "dist/src/storage.js")).href),
  import(pathToFileURL(join(serverRoot, "dist/src/invite.js")).href),
]);

const dataDir = process.env.OPPI_DATA_DIR;
if (!dataDir) {
  throw new Error("OPPI_DATA_DIR is required");
}

const inviteHost = process.env.E2E_APP_HOST || "127.0.0.1";
const storage = new Storage(dataDir);
// The wrapper writes the invite before sim-pool leases a simulator, so the
// token must outlive the slot wait plus a cold build on a busy shared pool;
// 10 minutes expired there ("Invite link expired or was already used").
// A gate lane runs with OPPI_SIM_POOL_WAIT=1800 s (scripts/batch-gate.ts), and
// sim-pool bounds each of its three waits by that value: the simulator slot, the
// booted-simulator ceiling, and a new device's first-boot slot. The wrapper also
// waits for an xcode-build slot and builds first: 3 x 30 min of waits plus a
// 60 min build budget.
const invite = generateInvite(storage, () => inviteHost, () => "e2e-server", {
  pairingTokenTtlMs: 150 * 60_000,
});

console.log(JSON.stringify({ inviteURL: invite.inviteURL, inviteHost }));
