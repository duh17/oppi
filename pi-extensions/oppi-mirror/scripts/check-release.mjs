#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(packageRoot, "../..");

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

function readProtocolVersion(source, constantName, path) {
  const match = source.match(
    new RegExp(`export const ${constantName}\\s*=\\s*(\\d+)\\s*;`),
  );
  if (!match) {
    throw new Error(`Could not read ${constantName} from ${path}`);
  }
  return Number(match[1]);
}

const mirrorPackagePath = resolve(packageRoot, "package.json");
const mirrorContractPath = resolve(
  packageRoot,
  "extensions/oppi-mirror-contract.ts",
);
const serverContractPath = resolve(
  repoRoot,
  "server/src/pi-tui-mirror-contract.ts",
);

const [mirrorPackage, mirrorContract, serverContract] = await Promise.all([
  readJson(mirrorPackagePath),
  readFile(mirrorContractPath, "utf8"),
  readFile(serverContractPath, "utf8"),
]);

const failures = [];

const mirrorProtocolVersion = readProtocolVersion(
  mirrorContract,
  "OPPI_MIRROR_BRIDGE_PROTOCOL_VERSION",
  mirrorContractPath,
);
const serverProtocolVersion = readProtocolVersion(
  serverContract,
  "PI_TUI_MIRROR_BRIDGE_PROTOCOL_VERSION",
  serverContractPath,
);
if (mirrorProtocolVersion !== serverProtocolVersion) {
  failures.push(
    `bridge protocol ${mirrorProtocolVersion} does not match oppi-server ${serverProtocolVersion}`,
  );
}

if (failures.length > 0) {
  console.error("oppi-mirror release check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log(
    `oppi-mirror release check passed: independent package version ${mirrorPackage.version}, bridge protocol ${mirrorProtocolVersion}`,
  );
}
