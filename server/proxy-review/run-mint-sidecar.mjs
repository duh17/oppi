#!/usr/bin/env node
/**
 * App Review mint sidecar. Bind to loopback or an internal port that the
 * public reverse proxy does not forward. Uses `oppi pair --json` on the
 * shared data dir. Never log the secret or invite URL.
 *
 * Loads the TypeScript mint server from the built oppi-server tree so revoke
 * and bind rules stay in one place.
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const secret = process.env.REVIEW_MINT_SECRET || "";
if (secret.length < 16) {
  throw new Error("REVIEW_MINT_SECRET must be at least 16 characters");
}
const listenHost = process.env.REVIEW_MINT_HOST || "127.0.0.1";
const listenPort = Number(process.env.REVIEW_MINT_PORT || "8790");
const allowNonLoopback =
  process.env.REVIEW_MINT_ALLOW_NON_LOOPBACK === "1" ||
  process.env.REVIEW_MINT_ALLOW_NON_LOOPBACK === "true";
const dataDir = process.env.OPPI_DATA_DIR;
if (!dataDir) {
  throw new Error("OPPI_DATA_DIR is required so mint/revoke target the origin data dir");
}

function resolveBuiltModule(basename) {
  const here = dirname(fileURLToPath(import.meta.url));
  const extra =
    basename === "review-mint-server" && process.env.REVIEW_MINT_MODULE
      ? [process.env.REVIEW_MINT_MODULE]
      : [];
  const cli = process.env.OPPI_TEST_CLI;
  const candidates = [
    ...extra,
    cli ? join(dirname(cli), `${basename}.js`) : "",
    `/opt/server/dist/src/${basename}.js`,
    join(here, `../dist/src/${basename}.js`),
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return pathToFileURL(candidate).href;
  }
  throw new Error(`review mint cannot load ${basename}.js; build oppi-server first`);
}

const { createReviewMintServer } = await import(resolveBuiltModule("review-mint-server"));
const { Storage } = await import(resolveBuiltModule("storage"));

function mint() {
  const output = execFileSync("oppi", ["pair", "--json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env,
  });
  const parsed = JSON.parse(output);
  if (typeof parsed.inviteURL !== "string" || !parsed.inviteURL.startsWith("oppi://")) {
    throw new Error("oppi pair did not return an invite URL");
  }
  return { inviteURL: parsed.inviteURL, expiresAt: Date.now() + 90_000 };
}

function invalidate() {
  const storage = new Storage(dataDir);
  storage.clearPairingToken();
}

const { listen } = createReviewMintServer({
  secret,
  listenHost,
  listenPort,
  allowNonLoopback,
  mint,
  invalidate,
  log(message) {
    process.stdout.write(`${message}\n`);
  },
});

const bound = await listen();
process.stdout.write(`review mint listening on ${bound.host}:${bound.port}\n`);
