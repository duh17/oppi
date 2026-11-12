#!/usr/bin/env node
// Fail unless the installed Bun is the version server/.bun-version pins: the Bun test lane
// (`npm run test:bun`, the pre-push `server-bun` lane) runs on exactly the runtime the Mac app
// bundles, so a different Bun would prove nothing about it. Runs under Node because a missing
// Bun must produce this message, not a shell "command not found".
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pinFile = join(dirname(fileURLToPath(import.meta.url)), "..", ".bun-version");
const pinned = readFileSync(pinFile, "utf8").trim();
const probe = spawnSync("bun", ["--version"], { encoding: "utf8" });

if (probe.error || probe.status !== 0) {
  console.error(
    `bun ${pinned} is required for the Bun test lane (pinned in server/.bun-version), but \`bun --version\` failed: ${probe.error?.message ?? probe.stderr.trim()}`,
  );
  console.error(`Install it: curl -fsSL https://bun.sh/install | bash -s "bun-v${pinned}"`);
  process.exit(1);
}
const installed = probe.stdout.trim();
if (installed !== pinned) {
  console.error(
    `The Bun test lane expects bun ${pinned} (pinned in server/.bun-version); found ${installed}.`,
  );
  console.error(
    `Install the pinned version (curl -fsSL https://bun.sh/install | bash -s "bun-v${pinned}"), or update server/.bun-version with the Bun the Mac app bundles.`,
  );
  process.exit(1);
}
