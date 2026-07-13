#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";

const ports = (process.env.E2E_CLEAN_PORTS || process.env.E2E_PORT || "17760")
  .split(",")
  .map((value) => Number(value.trim()))
  .filter((value) => Number.isInteger(value) && value > 0);

function listPidsOnPort(port) {
  const result = spawnSync("lsof", ["-tiTCP:" + port, "-sTCP:LISTEN"], {
    encoding: "utf-8",
  });
  if (result.status !== 0 && !result.stdout.trim()) return [];
  return result.stdout
    .split(/\s+/)
    .map((value) => Number(value))
    .filter((value) => Number.isInteger(value) && value > 0);
}

function commandForPid(pid) {
  const result = spawnSync("ps", ["-p", String(pid), "-o", "command="], {
    encoding: "utf-8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function killPid(pid, label) {
  try {
    process.kill(pid, "SIGTERM");
    console.log(`[e2e-clean] SIGTERM ${pid} ${label}`);
  } catch (error) {
    console.warn(`[e2e-clean] could not SIGTERM ${pid}: ${error.message}`);
    return;
  }

  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    } catch {
      return;
    }
  }

  try {
    process.kill(pid, "SIGKILL");
    console.log(`[e2e-clean] SIGKILL ${pid} ${label}`);
  } catch {
    // Already gone.
  }
}

for (const port of ports) {
  for (const pid of listPidsOnPort(port)) {
    const command = commandForPid(pid);
    if (command.includes("dist/src/cli.js serve") || command.includes("src/cli.ts serve")) {
      killPid(pid, `(port ${port}) ${command}`);
    } else {
      console.warn(`[e2e-clean] leaving non-Oppi listener on ${port}: pid=${pid} ${command}`);
    }
  }
}

if (process.env.E2E_NATIVE === "1" || process.env.E2E_SKIP_DOCKER_CLEAN === "1") {
  console.log("[e2e-clean] skipped Docker cleanup for native mode");
} else {
  const docker = spawnSync("docker", ["ps", "-aq", "--filter", "name=^/oppi-e2e$"], {
    encoding: "utf-8",
  });
  const containerIds = docker.status === 0 ? docker.stdout.split(/\s+/).filter(Boolean) : [];
  for (const id of containerIds) {
    try {
      execFileSync("docker", ["rm", "-f", id], { stdio: "inherit" });
      console.log(`[e2e-clean] removed docker container ${id}`);
    } catch (error) {
      console.warn(`[e2e-clean] could not remove docker container ${id}: ${error.message}`);
    }
  }
}
