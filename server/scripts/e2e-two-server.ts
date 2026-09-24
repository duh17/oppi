#!/usr/bin/env bun
/** Isolated native two-server iOS journey. Run from the checkout with:
 * bun server/scripts/e2e-two-server.ts
 * The ordinary sim-test owns the first server; this wrapper owns only the second.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createTCPServer } from "node:net";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { randomUUID } from "node:crypto";

const root = resolve(import.meta.dir, "../..");
const serverDir = join(root, "server");
const workflow = join(process.env.HOME ?? "", ".pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh");
const dataDir = await mkdtemp(join(tmpdir(), "oppi-e2e-second-"));
const name = "Offline E2E";
let second: ChildProcess | undefined;
let first: ChildProcess | undefined;
let stoppedForTest = false;
let failed = true;
const controlPath = `/offline/${randomUUID()}`;
const fixturePath = "/tmp/oppi-e2e-two-server.json";
let ownsFixture = false;

async function freePort(): Promise<number> {
  const socket = createTCPServer();
  await new Promise<void>((ok, fail) => socket.once("error", fail).listen(0, "127.0.0.1", ok));
  const address = socket.address();
  if (!address || typeof address === "string") throw Error("Missing TCP port");
  await new Promise<void>((ok) => socket.close(() => ok()));
  return address.port;
}
function run(command: string, args: string[], env: NodeJS.ProcessEnv = process.env): Promise<string> {
  return new Promise((ok, fail) => {
    const child = spawn(command, args, { cwd: serverDir, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", fail);
    child.once("exit", (code) => code === 0 ? ok(stdout.trim()) : fail(Error(`${command} exited ${code}: ${stderr}`)));
  });
}
async function stopSecond(): Promise<void> {
  const child = second;
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((ok) => {
    child.once("exit", () => ok());
    child.kill("SIGTERM");
    setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); }, 5000).unref();
  });
}
const control = createServer(async (request, response) => {
  if (request.method !== "POST" || request.url !== controlPath || stoppedForTest) {
    response.writeHead(404).end();
    return;
  }
  // The UI calls this only after it has verified both servers are paired.
  stoppedForTest = true;
  await stopSecond();
  response.writeHead(200).end("offline");
});
try {
  // Never let the stock harness's stale-port cleaner touch an existing listener.
  const firstPort = await freePort();
  const secondPort = await freePort();
  if (firstPort === secondPort) throw Error("E2E ports collided");
  await run("npm", ["run", "build"]);
  const env = { ...process.env, OPPI_DATA_DIR: dataDir };
  await run("node", ["dist/src/cli.js", "config", "set", "port", String(secondPort)], env);
  await run("node", ["dist/src/cli.js", "config", "set", "host", "0.0.0.0"], env);
  await run("node", ["dist/src/cli.js", "config", "set", "tls", '{"mode":"self-signed"}'], env);
  await run("node", ["--input-type=module", "-e", 'import { Storage } from "./dist/src/storage.js"; new Storage(process.env.OPPI_DATA_DIR).ensurePaired();'], env);
  const logPath = join(dataDir, "server.log");
  const logFD = openSync(logPath, "a");
  second = spawn("node", ["dist/src/cli.js", "serve"], {
    cwd: serverDir,
    env: { ...env, OPPI_LOCAL_SESSIONS_ROOT: join(dataDir, "pi-agent/sessions"), PI_CODING_AGENT_DIR: join(dataDir, "pi-agent"), OPPI_E2E_UI_HARNESS: "1" },
    stdio: ["ignore", logFD, logFD],
  });
  closeSync(logFD);
  // Health is unauthenticated and is used only to check this child, never to attach.
  let healthy = false;
  for (let i = 0; i < 80; i++) {
    if (second.exitCode !== null) throw Error(`Second E2E server exited ${second.exitCode}`);
    try {
      await run("curl", ["-kfsS", "--max-time", "1", `https://127.0.0.1:${secondPort}/health`]);
      healthy = true;
      break;
    } catch { /* first TLS bootstrap */ }
    await Bun.sleep(500);
  }
  if (!healthy) throw Error(`Second E2E server unhealthy; log: ${logPath}`);
  // Seed a real workspace before issuing the app's single-use invite.
  const token = await run("node", ["--input-type=module", "-e", 'import { Storage } from "./dist/src/storage.js"; console.log(new Storage(process.env.OPPI_DATA_DIR).issuePairingToken(600000));'], env);
  const access = await run("node", ["scripts/e2e-precreate-pair.mjs"], {
    ...env, NODE_TLS_REJECT_UNAUTHORIZED: "0", PAIRING_TOKEN: token,
    E2E_BASE_URL: `https://127.0.0.1:${secondPort}`,
  });
  await run("node", ["--input-type=module", "-e", `
    const response = await fetch(process.env.E2E_BASE_URL + "/workspaces", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + process.env.E2E_ACCESS_TOKEN },
      body: JSON.stringify({ name: "Offline E2E Workspace", hostMount: "/tmp", skills: [] }),
    });
    if (!response.ok) throw Error("Second E2E workspace seed failed: " + response.status + " " + await response.text());
  `], { ...env, NODE_TLS_REJECT_UNAUTHORIZED: "0", E2E_BASE_URL: `https://127.0.0.1:${secondPort}`, E2E_ACCESS_TOKEN: access });
  const invite = await run("node", ["--input-type=module", "-e", `
    import { Storage } from "./dist/src/storage.js";
    import { generateInvite } from "./dist/src/invite.js";
    const s = new Storage(process.env.OPPI_DATA_DIR);
    console.log(generateInvite(s, () => process.env.E2E_APP_HOST || "127.0.0.1", () => "${name}", { requestedName: "${name}", pairingTokenTtlMs: 600000 }).inviteURL);
  `], env);
  await new Promise<void>((ok, fail) => control.once("error", fail).listen(0, "127.0.0.1", ok));
  const address = control.address();
  if (!address || typeof address === "string") throw Error("Missing control port");
  const controlURL = `http://127.0.0.1:${address.port}${controlPath}`;
  // Xcode's test runner reads /tmp directly, as E2ETestCase does for the first invite.
  // Exclusive creation prevents one isolated run from replacing another's fixture.
  await writeFile(fixturePath, JSON.stringify({ invite, stopURL: controlURL, firstPort: String(firstPort) }), { mode: 0o600, flag: "wx" });
  ownsFixture = true;
  console.log(`[two-server] isolated first port=${firstPort} second port=${secondPort} second PID=${second.pid} data=${dataDir}`);
  first = spawn(workflow, ["sim-test", "--native", "--record-video=always", "--only-testing", "OppiE2ETests/OfflinePairedServerE2ETests"], {
    cwd: root, stdio: "inherit",
    env: {
      ...process.env, OPPI_ROOT: root, E2E_PORT: String(firstPort),
      E2E_APP_HOST: "127.0.0.1",
      SECOND_E2E_INVITE: invite, SIMCTL_CHILD_SECOND_E2E_INVITE: invite,
      SECOND_E2E_OFFLINE_URL: controlURL, SIMCTL_CHILD_SECOND_E2E_OFFLINE_URL: controlURL,
    },
  });
  const exit = await new Promise<number>((ok, fail) => { first?.once("error", fail); first?.once("exit", (code) => ok(code ?? 1)); });
  failed = exit !== 0 || !stoppedForTest;
  if (!stoppedForTest) console.error("[two-server] test did not request offline transition");
  if (exit !== 0) console.error(`[two-server] sim-test exited ${exit}`);
} catch (error) {
  console.error("[two-server]", error);
} finally {
  control.close();
  if (ownsFixture) await rm(fixturePath);
  await stopSecond();
  if (failed) console.error(`[two-server] preserving failure data: ${dataDir}`);
  else await rm(dataDir, { recursive: true, force: true });
}
process.exitCode = failed ? 1 : 0;
