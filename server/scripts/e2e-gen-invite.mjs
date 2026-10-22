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
const invite = generateInvite(storage, () => inviteHost, () => "e2e-server", {
  pairingTokenTtlMs: 45 * 60_000,
});

console.log(JSON.stringify({ inviteURL: invite.inviteURL, inviteHost }));
