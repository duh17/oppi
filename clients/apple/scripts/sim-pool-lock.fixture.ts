#!/usr/bin/env bun
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { tryAcquireSlot } from "./sim-pool-lock";

async function main(): Promise<void> {
  const mode = process.argv[2];
  const lockDir = process.argv[3];
  const slot = Number(process.argv[4]);
  const readyPath = process.argv[5];
  const childPath = process.argv[6];

  if (!mode || !lockDir || Number.isNaN(slot) || !readyPath) {
    console.error("usage: hold|hold-with-child lockDir slot readyPath [childPidPath]");
    process.exit(2);
  }

  const acquired = tryAcquireSlot({
    lockDir,
    slot,
    argv: ["fixture", mode],
  });
  if (!acquired.ok) {
    console.error(acquired.reason);
    process.exit(1);
  }

  if (mode === "hold-with-child") {
    if (!childPath) {
      console.error("child pid path required");
      process.exit(2);
    }
    const child = spawn("sleep", ["60"], {
      stdio: "ignore",
      detached: true,
    });
    if (child.pid == null) {
      process.exit(1);
    }
    writeFileSync(childPath, `${child.pid}\n`);
  }

  writeFileSync(readyPath, "ready\n");
  await Bun.sleep(60_000);
  process.exit(0);
}

void main();
