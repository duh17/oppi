import { afterEach, describe, expect, it } from "vitest";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ConfigStore } from "../src/storage/config-store.js";
import { Storage } from "../src/storage.js";

const SIDECAR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../proxy-review/run-mint-sidecar.mjs",
);
const SECRET = "rp39-sidecar-secret-value";

function freeLoopbackPort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => {
        if (error) reject(error);
        else if (!address || typeof address === "string") reject(new Error("port bind failed"));
        else resolvePort(address.port);
      });
    });
  });
}

function writeFakeOppi(
  binDir: string,
  counterPath: string,
  dataDir: string,
  options: { failOncePath?: string } = {},
): void {
  const script = `#!/usr/bin/env node
const { appendFileSync, existsSync, readFileSync, unlinkSync, writeFileSync } = require("node:fs");
const failOncePath = ${JSON.stringify(options.failOncePath ?? "")};
if (failOncePath && existsSync(failOncePath)) {
  unlinkSync(failOncePath);
  process.stderr.write("forced pair failure\\n");
  process.exit(1);
}
appendFileSync(${JSON.stringify(counterPath)}, "pair\\n");
const n = readFileSync(${JSON.stringify(counterPath)}, "utf8").trim().split("\\n").length;
const pairingToken = "pt_sidecar_" + n;
const inviteURL = "oppi://connect?invite=sidecar-" + n;
const configPath = ${JSON.stringify(join(dataDir, "config.json"))};
const config = JSON.parse(readFileSync(configPath, "utf8"));
config.pairingToken = pairingToken;
config.pairingTokenExpiresAt = Date.now() + 90_000;
writeFileSync(configPath, JSON.stringify(config));
process.stdout.write(JSON.stringify({ inviteURL, pairingToken }) + "\\n");
`;
  writeFileSync(join(binDir, "oppi"), script, { mode: 0o755 });
  chmodSync(join(binDir, "oppi"), 0o755);
}

function mintRequest(
  port: number,
  path: string,
  options: { method?: string; headers?: Record<string, string> } = {},
): Promise<{ status: number; location?: string; cacheControl?: string; body: string }> {
  return new Promise((resolveResponse, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method: options.method ?? "GET",
        headers: options.headers,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(chunk as Buffer));
        res.on("end", () => {
          resolveResponse({
            status: res.statusCode ?? 0,
            location: typeof res.headers.location === "string" ? res.headers.location : undefined,
            cacheControl:
              typeof res.headers["cache-control"] === "string"
                ? res.headers["cache-control"]
                : undefined,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

describe("review mint sidecar", () => {
  const dirs: string[] = [];
  const children: ChildProcessWithoutNullStreams[] = [];

  afterEach(() => {
    for (const child of children.splice(0)) {
      child.kill("SIGTERM");
    }
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reuses one invite, remints after consume or external pair, and invalidates outstanding invite without mint-and-discard", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-mint-sidecar-"));
    dirs.push(root);
    const dataDir = join(root, "data");
    const binDir = join(root, "bin");
    mkdirSync(dataDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    const counterPath = join(root, "pair-calls.txt");
    writeFileSync(counterPath, "");
    writeFakeOppi(binDir, counterPath, dataDir);
    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        ...ConfigStore.getDefaultConfig(dataDir),
        host: "127.0.0.1",
        token: "sk_test_sidecar",
        pairingToken: "pt_live_before_revoke",
        pairingTokenExpiresAt: Date.now() + 90_000,
      }),
    );

    const port = await freeLoopbackPort();
    const child = spawn(process.execPath, [SIDECAR], {
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        OPPI_DATA_DIR: dataDir,
        REVIEW_MINT_SECRET: SECRET,
        REVIEW_MINT_HOST: "127.0.0.1",
        REVIEW_MINT_PORT: String(port),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    const logs: string[] = [];
    child.stdout.on("data", (chunk) => logs.push(chunk.toString("utf8")));
    child.stderr.on("data", (chunk) => logs.push(chunk.toString("utf8")));
    await waitForLog(logs, /review mint listening/, 8_000);

    const first = await mintRequest(port, `/r/${SECRET}`);
    const second = await mintRequest(port, `/r/${SECRET}`);
    expect(first.status).toBe(302);
    expect(second.status).toBe(302);
    expect(first.location).toBe(second.location);
    expect(first.location?.startsWith("oppi://connect")).toBe(true);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual(["pair"]);

    new Storage(dataDir).clearPairingToken();
    const afterConsume = await mintRequest(port, `/r/${SECRET}`);
    expect(afterConsume.status).toBe(302);
    expect(afterConsume.location).not.toBe(first.location);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual(["pair", "pair"]);

    const retried = await mintRequest(port, `/r/${SECRET}?retry=1`);
    expect(retried.status).toBe(302);
    expect(retried.location).not.toBe(afterConsume.location);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual(["pair", "pair", "pair"]);

    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        ...JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8")),
        pairingToken: "pt_external_replacement",
        pairingTokenExpiresAt: Date.now() + 90_000,
      }),
    );
    const afterExternal = await mintRequest(port, `/r/${SECRET}`);
    expect(afterExternal.status).toBe(302);
    expect(afterExternal.location).not.toBe(retried.location);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual([
      "pair",
      "pair",
      "pair",
      "pair",
    ]);

    const preview = await mintRequest(port, `/r/${SECRET}`, {
      headers: { "User-Agent": "facebookexternalhit/1.1" },
    });
    expect(preview.status).toBe(200);
    expect(preview.body).not.toContain("oppi://connect");

    const head = await mintRequest(port, `/r/${SECRET}`, { method: "HEAD" });
    expect(head.status).toBe(405);

    const revoked = await mintRequest(port, `/r/${SECRET}/invalidate-invite`, { method: "POST" });
    expect(revoked.status).toBe(204);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual([
      "pair",
      "pair",
      "pair",
      "pair",
    ]);
    expect(new Storage(dataDir).getConfig().pairingToken).toBeUndefined();
    expect(logs.join("")).not.toContain(SECRET);
    expect(logs.join("")).not.toContain("oppi://connect");
    expect(logs.join("")).not.toContain("pt_sidecar_");
  }, 15_000);

  it("stays up after a mint failure and succeeds on the next open", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-mint-sidecar-fail-"));
    dirs.push(root);
    const dataDir = join(root, "data");
    const binDir = join(root, "bin");
    mkdirSync(dataDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    const counterPath = join(root, "pair-calls.txt");
    const failOncePath = join(root, "fail-once");
    writeFileSync(counterPath, "");
    writeFileSync(failOncePath, "1");
    writeFakeOppi(binDir, counterPath, dataDir, { failOncePath });
    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        ...ConfigStore.getDefaultConfig(dataDir),
        host: "127.0.0.1",
        token: "sk_test_sidecar",
      }),
    );

    const port = await freeLoopbackPort();
    const child = spawn(process.execPath, [SIDECAR], {
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        OPPI_DATA_DIR: dataDir,
        REVIEW_MINT_SECRET: SECRET,
        REVIEW_MINT_HOST: "127.0.0.1",
        REVIEW_MINT_PORT: String(port),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    const logs: string[] = [];
    child.stdout.on("data", (chunk) => logs.push(chunk.toString("utf8")));
    child.stderr.on("data", (chunk) => logs.push(chunk.toString("utf8")));
    await waitForLog(logs, /review mint listening/, 8_000);

    const failed = await mintRequest(port, `/r/${SECRET}`);
    expect(failed.status).toBe(503);
    expect(failed.cacheControl).toBe("no-store");
    expect(failed.location).toBeUndefined();
    expect(failed.body).toBe("");
    expect(failed.body).not.toContain("forced pair failure");
    expect(child.exitCode).toBeNull();

    const recovered = await mintRequest(port, `/r/${SECRET}`);
    expect(recovered.status).toBe(302);
    expect(recovered.location?.startsWith("oppi://connect")).toBe(true);
    expect(readFileSync(counterPath, "utf8").trim().split("\n")).toEqual(["pair"]);
    expect(logs.join("")).not.toContain(SECRET);
    expect(logs.join("")).not.toContain("oppi://connect");
  }, 15_000);

  it("refuses a non-loopback mint bind unless explicitly allowed", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-mint-sidecar-bind-"));
    dirs.push(root);
    const dataDir = join(root, "data");
    mkdirSync(dataDir, { recursive: true });
    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        ...ConfigStore.getDefaultConfig(dataDir),
        host: "127.0.0.1",
        token: "sk_test_sidecar",
      }),
    );
    const child = spawn(process.execPath, [SIDECAR], {
      env: {
        ...process.env,
        OPPI_DATA_DIR: dataDir,
        REVIEW_MINT_SECRET: SECRET,
        REVIEW_MINT_HOST: "0.0.0.0",
        REVIEW_MINT_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    const output = await waitForExit(child, 8_000);
    expect(output.code).not.toBe(0);
    expect(output.text).toMatch(/non-loopback bind 0\.0\.0\.0/);
  }, 10_000);
});

async function waitForLog(logs: string[], pattern: RegExp, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pattern.test(logs.join(""))) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`sidecar did not log ${pattern}\n${logs.join("")}`);
}

function waitForExit(
  child: ChildProcessWithoutNullStreams,
  timeoutMs: number,
): Promise<{ code: number | null; text: string }> {
  return new Promise((resolve, reject) => {
    const chunks: string[] = [];
    const onData = (chunk: Buffer) => chunks.push(chunk.toString("utf8"));
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`sidecar did not exit\n${chunks.join("")}`));
    }, timeoutMs);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, text: chunks.join("") });
    });
  });
}
