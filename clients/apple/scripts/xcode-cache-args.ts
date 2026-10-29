#!/usr/bin/env bun
// Prints, NUL-separated, the xcodebuild arguments that share sim-pool's SwiftPM clone and compilation
// cache (see `sharedCacheArguments` in sim-pool-build.ts), for builds outside `sim-pool run`:
//
//   xcode-cache-args.ts <derivedDataPath>
//
// DEVELOPER_DIR picks the Xcode's cache; set it to the toolchain the build uses.
import { dirname, resolve } from "node:path";
import { sharedCacheArguments } from "./sim-pool-build";

const derivedData = process.argv[2];
if (!derivedData) {
  console.error("usage: xcode-cache-args.ts <derivedDataPath>");
  process.exit(2);
}
const appleDir = resolve(dirname(import.meta.path), "..");
process.stdout.write(sharedCacheArguments(process.env, appleDir, resolve(derivedData)).map((arg) => `${arg}\0`).join(""));
