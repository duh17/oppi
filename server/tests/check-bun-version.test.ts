import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const script = join(import.meta.dirname, "..", "scripts", "check-bun-version.mjs");
const pinned = readFileSync(join(import.meta.dirname, "..", ".bun-version"), "utf8").trim();

// The script runs with a PATH holding only a stub `bun` (or nothing), so the host's Bun
// cannot answer for it.
let dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  dirs = [];
});

function run(stubVersion: string | null) {
  const bin = mkdtempSync(join(tmpdir(), "bun-pin-"));
  dirs.push(bin);
  if (stubVersion !== null) {
    const stub = join(bin, "bun");
    writeFileSync(stub, `#!/bin/sh\necho ${stubVersion}\n`);
    chmodSync(stub, 0o755);
  }
  return spawnSync(process.execPath, [script], { encoding: "utf8", env: { PATH: bin } });
}

describe("Bun lane version pin", () => {
  it("passes when the installed Bun is the pinned one", () => {
    expect(run(pinned).status).toBe(0);
  });

  it("names both versions when the installed Bun differs", () => {
    const result = run("0.0.1");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`expects bun ${pinned}`);
    expect(result.stderr).toContain("found 0.0.1");
  });

  it("says Bun is missing instead of failing on the spawn", () => {
    const result = run(null);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`bun ${pinned} is required`);
  });
});
