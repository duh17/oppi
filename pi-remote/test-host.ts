/**
 * Test: host directory discovery.
 */

import { scanDirectories, discoverProjects } from "./src/host.js";

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  ✓ ${message}`);
    passed++;
  } else {
    console.error(`  ✗ ${message}`);
    failed++;
  }
}

console.log("\n=== Host Directory Discovery ===\n");

// Test scanning a real directory
console.log("Scan ~/workspace:");
const dirs = scanDirectories("~/workspace");
console.log(`  Found ${dirs.length} project(s)`);

assert(dirs.length > 0, "Found at least one project");

// Check that pios is found (we're in it!)
const pios = dirs.find(d => d.name === "pios");
assert(pios !== undefined, "Found pios directory");
if (pios) {
  assert(pios.isGitRepo, "pios is a git repo");
  assert(pios.hasAgentsMd, "pios has AGENTS.md");
  assert(pios.path.startsWith("~"), "Path uses ~ prefix");
  console.log(`  pios: ${JSON.stringify(pios, null, 2)}`);
}

// Test discoverProjects (multi-root)
console.log("\nDiscover projects (default roots):");
const all = discoverProjects();
console.log(`  Found ${all.length} project(s) across all roots`);
assert(all.length > 0, "Found projects");

// Show all for inspection
for (const d of all.slice(0, 10)) {
  const tags = [
    d.isGitRepo ? "git" : "",
    d.hasAgentsMd ? "agents.md" : "",
    d.language || "",
    d.gitRemote || "",
  ].filter(Boolean).join(", ");
  console.log(`  ${d.name.padEnd(25)} ${tags}`);
}
if (all.length > 10) {
  console.log(`  ... and ${all.length - 10} more`);
}

// Test scanning non-existent directory
console.log("\nScan non-existent directory:");
const empty = scanDirectories("~/nonexistent-dir-xyz");
assert(empty.length === 0, "Returns empty for non-existent dir");

// Test filtering (should skip hidden dirs and node_modules)
console.log("\nFiltering:");
const names = dirs.map(d => d.name);
assert(!names.includes("node_modules"), "Skips node_modules");
assert(!names.includes(".git"), "Skips hidden directories");

console.log(`\n--- Results: ${passed} passed, ${failed} failed ---\n`);
process.exit(failed > 0 ? 1 : 0);
