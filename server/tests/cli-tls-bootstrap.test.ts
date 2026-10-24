/**
 * CLI integration tests: first-run TLS bootstrap for serve, pair, and init.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CLI } from "./harness/cli-process.js";
import {
  cliProcessEnv,
  connectedTailscaleEnv,
  disconnectedTailscaleEnv,
  generateDoctorCertificate,
  getFreePort,
  run,
  runAsync,
  runUntilOutput,
  stripAnsi,
  TERMINAL_STDOUT_ENV,
  useCliDataDir,
} from "./harness/cli-test-env.js";

useCliDataDir();

function setCliConfig(dir: string, key: string, value: string): void {
  const { exitCode } = run(["config", "set", key, value], { OPPI_DATA_DIR: dir });
  expect(exitCode).toBe(0);
}

function readTlsMode(dir: string): string | undefined {
  const { stdout, exitCode } = run(["config", "get", "tls"], { OPPI_DATA_DIR: dir });
  expect(exitCode).toBe(0);
  return (JSON.parse(stdout) as { mode?: string }).mode;
}

function decodeConnectInvite(stdout: string): {
  host?: string;
  port?: number;
  scheme?: string;
  tlsCertFingerprint?: string;
} {
  const link = stripAnsi(stdout).match(/oppi:\/\/connect\?[^\s]+/);
  expect(link).not.toBeNull();
  const invite = new URL(link![0]).searchParams.get("invite");
  expect(invite).toBeTruthy();
  const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
    signedPayload?: string;
  };
  expect(envelope.signedPayload).toBeTruthy();
  return JSON.parse(Buffer.from(envelope.signedPayload!, "base64url").toString("utf-8")) as {
    host?: string;
    port?: number;
    scheme?: string;
    tlsCertFingerprint?: string;
  };
}

describe("first-run tls bootstrap (serve, pair, init)", () => {
  const tailnetHost = "node.tail00000.ts.net";

  // The fake binary is selected through OPPI_TAILSCALE_BIN: `serve`, `pair`, and
  // `init` replace PATH with config.runtimePathEntries before they look for it.
  function serveWithTailscale(
    serveDir: string,
    tailscaleEnv: Record<string, string>,
  ): Record<string, string> {
    return {
      OPPI_DATA_DIR: serveDir,
      OPPI_TAILSCALE_BIN: tailscaleEnv.OPPI_TAILSCALE_BIN!,
      ...TERMINAL_STDOUT_ENV,
    };
  }

  /**
   * Fresh-host config for `serve`: only the test port and loopback bind. No
   * `tls` key, so the stored default decides.
   */
  async function writeConfigWithoutTls(serveDir: string): Promise<void> {
    writeFileSync(
      join(serveDir, "config.json"),
      JSON.stringify({ port: await getFreePort(), host: "127.0.0.1" }),
    );
  }

  function issueTailnetCert(dir: string): { certPath: string; keyPath: string } {
    const fixtureDir = join(dir, "issued");
    mkdirSync(fixtureDir, { recursive: true });
    const certFixture = {
      certPath: join(fixtureDir, "server.crt"),
      keyPath: join(fixtureDir, "server.key"),
    };
    generateDoctorCertificate(certFixture.certPath, certFixture.keyPath, tailnetHost);
    return certFixture;
  }

  it("upgrades legacy disabled TLS to self-signed on first serve when Tailscale is stopped", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-tls-"));

    try {
      setCliConfig(serveDir, "tls", '{"mode":"disabled"}');
      setCliConfig(serveDir, "port", String(await getFreePort()));
      setCliConfig(serveDir, "host", "127.0.0.1");
      expect(readTlsMode(serveDir)).toBe("disabled");

      // `serve` is long-running; stop it once startup reaches the invite output.
      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        serveWithTailscale(serveDir, disconnectedTailscaleEnv(serveDir)),
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).toContain("First run — TLS mode set to self-signed");
      // No tailnet, nothing to probe: no Tailscale noise and no empty cert dir.
      expect(strippedServe).not.toContain("Tailscale HTTPS");
      expect(existsSync(join(serveDir, "tls", "tailscale"))).toBe(false);
      expect(strippedServe).toContain("Scan this QR code in Oppi:");
      expect(strippedServe).toContain("oppi://connect?");
      expect(strippedServe).not.toContain("✓ Paired");
      expect(strippedServe).not.toContain("Waiting for connections...");
      expect(readTlsMode(serveDir)).toBe("self-signed");
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("fresh host: first serve uses Tailscale TLS and a *.ts.net invite when a certificate can be issued", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-tailscale-"));

    try {
      const certFixture = issueTailnetCert(serveDir);
      const tailscaleEnv = connectedTailscaleEnv(serveDir, tailnetHost, certFixture);
      await writeConfigWithoutTls(serveDir);

      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        serveWithTailscale(serveDir, tailscaleEnv),
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).toContain("First run — TLS mode set to tailscale");
      expect(strippedServe).not.toContain("TLS mode set to self-signed");
      expect(readTlsMode(serveDir)).toBe("tailscale");

      const invite = decodeConnectInvite(serveStdout);
      expect(invite).toMatchObject({ host: tailnetHost, scheme: "https" });
      // Tailscale certificates are publicly trusted; the invite carries no pin.
      expect(invite.tlsCertFingerprint).toBeUndefined();
      const installedCert = readFileSync(join(serveDir, "tls", "tailscale", "server.crt"));
      expect(installedCert.equals(readFileSync(certFixture.certPath))).toBe(true);
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("fresh host: first serve falls back to self-signed when Tailscale is connected but cannot issue a certificate", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-tailscale-nocert-"));

    try {
      await writeConfigWithoutTls(serveDir);

      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        serveWithTailscale(serveDir, connectedTailscaleEnv(serveDir, tailnetHost)),
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).toContain("Checking Tailscale HTTPS certificate");
      // One short line with tailscale's own reason, not our paths or file names.
      expect(strippedServe).toContain(
        "Tailscale HTTPS not ready (your Tailscale account does not support getting TLS certs); using self-signed TLS",
      );
      expect(strippedServe).not.toContain("certificate not found");
      expect(strippedServe).not.toContain(".tailscale-cert-");
      expect(strippedServe).toContain("First run — TLS mode set to self-signed");
      expect(readTlsMode(serveDir)).toBe("self-signed");
      expect(existsSync(join(serveDir, "tls", "tailscale"))).toBe(false);

      const invite = decodeConnectInvite(serveStdout);
      expect(invite.scheme).toBe("https");
      expect(invite.tlsCertFingerprint).toMatch(/^sha256:/);
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("keeps a TLS mode written while the certificate probe is still running", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-pair-race-config-"));

    try {
      const dataDirForPair = join(root, "data");
      const markerPath = join(root, "cert-started");
      const slowEnv = connectedTailscaleEnv(root, tailnetHost, issueTailnetCert(root), {
        markerPath,
        seconds: 4,
      });

      const pairing = runAsync(["pair", "--json"], { OPPI_DATA_DIR: dataDirForPair, ...slowEnv });
      const deadline = Date.now() + 20_000;
      while (!existsSync(markerPath) && Date.now() < deadline) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
      }
      expect(existsSync(markerPath)).toBe(true);

      // An operator (or another first-run command) decides while `pair` waits on
      // Tailscale. The probe succeeds afterwards; it must not replace this.
      setCliConfig(dataDirForPair, "tls", '{"mode":"self-signed"}');

      const result = await pairing;
      expect(result.exitCode).toBe(0);
      expect(readTlsMode(dataDirForPair)).toBe("self-signed");
      expect(stripAnsi(result.stderr)).not.toContain("First run — TLS mode set to");
      const invite = JSON.parse(result.stdout) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };
      expect(invite.host).not.toBe(tailnetHost);
      expect(invite.scheme).toBe("https");
      expect(invite.tlsCertFingerprint).toMatch(/^sha256:/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);

  it("two concurrent first-run pairs end with one stored mode and invites that match it", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-pair-race-two-"));

    try {
      const sharedDataDir = join(root, "data");
      const markerPath = join(root, "cert-started");
      // Slow, certificate-capable Tailscale: would choose tailscale when it finishes.
      const slowEnv = connectedTailscaleEnv(root, tailnetHost, issueTailnetCert(root), {
        markerPath,
        seconds: 4,
      });
      const first = runAsync(["pair", "--json"], { OPPI_DATA_DIR: sharedDataDir, ...slowEnv });
      const deadline = Date.now() + 20_000;
      while (!existsSync(markerPath) && Date.now() < deadline) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
      }
      expect(existsSync(markerPath)).toBe(true);

      // A second host view with no Tailscale finishes first and stores self-signed.
      const second = await runAsync(["pair", "--json"], { OPPI_DATA_DIR: sharedDataDir });
      expect(second.exitCode).toBe(0);
      const firstResult = await first;
      expect(firstResult.exitCode).toBe(0);

      expect(readTlsMode(sharedDataDir)).toBe("self-signed");
      for (const invite of [firstResult, second].map(
        (result) =>
          JSON.parse(result.stdout) as {
            host?: string;
            scheme?: string;
            tlsCertFingerprint?: string;
          },
      )) {
        expect(invite.host).not.toBe(tailnetHost);
        expect(invite.scheme).toBe("https");
        expect(invite.tlsCertFingerprint).toMatch(/^sha256:/);
      }
      expect(stripAnsi(firstResult.stderr)).not.toContain("First run — TLS mode set to tailscale");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);

  it("fresh host: `oppi init` says it is checking Tailscale HTTPS and stays quiet without Tailscale", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-init-quiet-"));

    try {
      const readyDir = join(root, "ready");
      const ready = run(
        ["init", "--yes", "--data-dir", readyDir],
        connectedTailscaleEnv(root, tailnetHost, issueTailnetCert(root)),
      );
      expect(ready.exitCode).toBe(0);
      expect(stripAnsi(ready.stdout)).toContain("Checking Tailscale HTTPS certificate");

      // The default env is a stopped Tailscale: nothing to check, nothing to say.
      const stoppedDir = join(root, "stopped");
      const stopped = run(["init", "--yes", "--data-dir", stoppedDir]);
      expect(stopped.exitCode).toBe(0);
      const out = stripAnsi(stopped.stdout);
      expect(out).toContain("TLS mode set to self-signed");
      expect(out).not.toContain("Tailscale");
      expect(existsSync(join(stoppedDir, "tls", "tailscale"))).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);

  it.each([
    { tls: { mode: "cloudflare" }, trustedProxy: false, field: "mode" },
    { tls: { mode: "cloudflare" }, trustedProxy: true, field: "mode" },
    { tls: { mode: "self-signed", certPath: "" }, trustedProxy: false, field: "certPath" },
  ])(
    "refuses to start with an invalid tls block and names the fix: $tls, proxy=$trustedProxy",
    async ({ tls, trustedProxy, field }) => {
      const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-invalid-tls-"));

      try {
        // Invalid TLS must refuse the network bind, including behind a trusted proxy.
        writeFileSync(
          join(serveDir, "config.json"),
          JSON.stringify({
            port: await getFreePort(),
            host: "0.0.0.0",
            token: "sk_paired_invalid_tls",
            tls,
          }),
        );
        setCliConfig(serveDir, "maxSessionsGlobal", "7");
        if (trustedProxy) {
          setCliConfig(serveDir, "publicUrl", "https://oppi.example.com");
          setCliConfig(serveDir, "proxy.trustedPeers", '["10.0.0.1/32"]');
        }
        expect(JSON.parse(readFileSync(join(serveDir, "config.json"), "utf8")).tls).toEqual(tls);

        // Stop on a listener announcement so a fail-open regression fails on its
        // observed behavior, not on a subprocess timeout.
        const { out, exitCode } = await new Promise<{ out: string; exitCode: number | null }>(
          (resolveRun, rejectRun) => {
            const child = spawn("node", [CLI, "serve"], {
              env: cliProcessEnv({ OPPI_DATA_DIR: serveDir }),
              stdio: ["ignore", "pipe", "pipe"],
            });
            let output = "";
            const timer = setTimeout(() => {
              child.kill("SIGKILL");
              rejectRun(
                new Error(`Invalid-TLS startup did not exit or announce a listener: ${output}`),
              );
            }, 15_000);
            const capture = (chunk: string) => {
              output += chunk;
              if (output.includes('"event":"server.listening"')) child.kill("SIGTERM");
            };
            child.stdout.setEncoding("utf8").on("data", capture);
            child.stderr.setEncoding("utf8").on("data", capture);
            child.once("error", (error) => {
              clearTimeout(timer);
              rejectRun(error);
            });
            child.once("close", (code) => {
              clearTimeout(timer);
              resolveRun({ out: stripAnsi(output), exitCode: code });
            });
          },
        );
        expect(out).not.toContain('"event":"server.listening"');
        expect(out).not.toContain("Listener:");
        expect(exitCode).not.toBe(0);
        expect(out).toContain(`config.tls.${field}`);
        expect(out).toContain("oppi config set tls.mode self-signed");
        expect(out).toContain("The invalid tls block loads as tls.mode=disabled");
      } finally {
        rmSync(serveDir, { recursive: true, force: true });
      }
    },
    60_000,
  );

  it("fresh host: `oppi pair` before any serve picks Tailscale TLS or self-signed from certificate readiness", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-pair-fresh-"));

    try {
      const readyDir = join(root, "ready");
      const readyEnv = connectedTailscaleEnv(root, tailnetHost, issueTailnetCert(root));
      const ready = run(["pair", "--json"], { OPPI_DATA_DIR: readyDir, ...readyEnv });
      expect(ready.exitCode).toBe(0);
      expect(JSON.parse(ready.stdout)).toMatchObject({ host: tailnetHost, scheme: "https" });
      expect(
        (JSON.parse(ready.stdout) as { tlsCertFingerprint?: string }).tlsCertFingerprint,
      ).toBeUndefined();
      expect(readTlsMode(readyDir)).toBe("tailscale");

      const notReadyRoot = join(root, "not-ready");
      mkdirSync(notReadyRoot);
      const notReadyDir = join(notReadyRoot, "data");
      const notReady = run(["pair", "--json"], {
        OPPI_DATA_DIR: notReadyDir,
        ...connectedTailscaleEnv(notReadyRoot, tailnetHost),
      });
      expect(notReady.exitCode).toBe(0);
      const notReadyInvite = JSON.parse(notReady.stdout) as {
        scheme?: string;
        tlsCertFingerprint?: string;
      };
      expect(notReadyInvite.scheme).toBe("https");
      expect(notReadyInvite.tlsCertFingerprint).toMatch(/^sha256:/);
      expect(readTlsMode(notReadyDir)).toBe("self-signed");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);

  it.each([{ mode: "disabled" }, { mode: "cloudflare" }, { mode: "self-signed", certPath: "" }])(
    "host with an owner token: `oppi init --yes --force` keeps the tls block: %j",
    (tls) => {
      const initDir = mkdtempSync(join(tmpdir(), "oppi-cli-init-paired-tls-"));

      try {
        writeFileSync(
          join(initDir, "config.json"),
          JSON.stringify({ host: "0.0.0.0", token: "sk_paired_init_tls", tls }),
        );
        const init = run(["init", "--yes", "--force", "--data-dir", initDir]);
        expect(init.exitCode).toBe(0);
        expect(JSON.parse(readFileSync(join(initDir, "config.json"), "utf8")).tls).toEqual(tls);
        expect(stripAnsi(init.stdout)).not.toContain("TLS mode set to");
      } finally {
        rmSync(initDir, { recursive: true, force: true });
      }
    },
  );

  it("keeps explicit insecure network HTTP on first init and does not call it undecided in doctor", () => {
    const initDir = mkdtempSync(join(tmpdir(), "oppi-cli-init-insecure-http-"));

    try {
      const tls = { mode: "disabled", allowInsecureNetworkHttp: true };
      writeFileSync(join(initDir, "config.json"), JSON.stringify({ tls }));
      const env = { OPPI_DATA_DIR: initDir };
      const doctor = run(["doctor"], env);
      const init = run(["init", "--yes", "--force", "--data-dir", initDir]);
      expect(init.exitCode).toBe(0);
      expect(JSON.parse(readFileSync(join(initDir, "config.json"), "utf8")).tls).toEqual(tls);
      expect(stripAnsi(init.stdout)).not.toContain("TLS mode set to");
      expect(stripAnsi(doctor.stdout)).toContain("TLS disabled while binding to 0.0.0.0");
      expect(stripAnsi(doctor.stdout)).not.toContain("not chosen yet");
    } finally {
      rmSync(initDir, { recursive: true, force: true });
    }
  });

  it("fresh host: `oppi init` picks Tailscale TLS when a certificate can be issued", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-init-fresh-"));

    try {
      const initDir = join(root, "data");
      const tailscaleEnv = connectedTailscaleEnv(root, tailnetHost, issueTailnetCert(root));
      const { stdout, exitCode } = run(["init", "--yes", "--data-dir", initDir], tailscaleEnv);
      expect(exitCode).toBe(0);
      expect(stripAnsi(stdout)).toContain("TLS mode set to tailscale");
      expect(readTlsMode(initDir)).toBe("tailscale");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 60_000);

  it("does not replace an explicitly configured TLS mode even when Tailscale can issue a certificate", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-explicit-tls-"));

    try {
      setCliConfig(serveDir, "tls", '{"mode":"self-signed"}');
      setCliConfig(serveDir, "port", String(await getFreePort()));
      setCliConfig(serveDir, "host", "127.0.0.1");
      const certFixture = issueTailnetCert(serveDir);

      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        serveWithTailscale(serveDir, connectedTailscaleEnv(serveDir, tailnetHost, certFixture)),
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).not.toContain("First run — TLS mode set to");
      expect(readTlsMode(serveDir)).toBe("self-signed");
      expect(decodeConnectInvite(serveStdout).tlsCertFingerprint).toMatch(/^sha256:/);
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("preserves disabled TLS for a trusted private-HTTP reverse proxy on first serve", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-proxy-tls-"));

    try {
      const freePort = await getFreePort();
      setCliConfig(serveDir, "host", "127.0.0.1");
      setCliConfig(serveDir, "port", String(freePort));
      setCliConfig(serveDir, "tls", '{"mode":"disabled"}');
      setCliConfig(serveDir, "publicUrl", "https://oppi.example.com");
      setCliConfig(serveDir, "proxy.trustedPeers", '["127.0.0.1/32","::1/128"]');
      expect(readTlsMode(serveDir)).toBe("disabled");

      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        { OPPI_DATA_DIR: serveDir, ...TERMINAL_STDOUT_ENV },
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).not.toContain("First run — TLS mode set to self-signed");
      expect(strippedServe).toContain("First run — owner token generated");
      expect(strippedServe).toContain("Public:    https://oppi.example.com");
      expect(strippedServe).toContain(
        `Listener:  http://127.0.0.1:${freePort} (tls.mode=disabled)`,
      );
      expect(strippedServe).toContain("Proxy:     trustedPeers 127.0.0.1, ::1");
      expect(strippedServe).toContain("Scan this QR code in Oppi:");
      expect(strippedServe).not.toContain("✓ Paired");
      expect(strippedServe).not.toContain("Waiting for connections...");
      expect(strippedServe).not.toContain("Cert pin:");

      const invite = decodeConnectInvite(serveStdout);
      expect(invite).toMatchObject({
        host: "oppi.example.com",
        port: 443,
        scheme: "https",
      });
      expect(invite.tlsCertFingerprint).toBeUndefined();
      expect(readTlsMode(serveDir)).toBe("disabled");
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("does not preserve disabled TLS when publicUrl is set without trustedPeers", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-publicurl-tls-"));

    try {
      const freePort = await getFreePort();
      setCliConfig(serveDir, "host", "127.0.0.1");
      setCliConfig(serveDir, "port", String(freePort));
      setCliConfig(serveDir, "tls", '{"mode":"disabled"}');
      setCliConfig(serveDir, "publicUrl", "https://oppi.example.com");
      expect(readTlsMode(serveDir)).toBe("disabled");

      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        serveWithTailscale(serveDir, disconnectedTailscaleEnv(serveDir)),
        60_000,
      );

      const strippedServe = stripAnsi(serveStdout);
      expect(strippedServe).toContain("First run — TLS mode set to self-signed");
      expect(strippedServe).toContain("Public:    https://oppi.example.com");
      expect(strippedServe).toContain(
        `Listener:  https://127.0.0.1:${freePort} (tls.mode=self-signed)`,
      );
      expect(strippedServe).not.toContain("Proxy:     trustedPeers");
      expect(strippedServe).not.toContain("✓ Paired");

      const invite = decodeConnectInvite(serveStdout);
      expect(invite).toMatchObject({
        host: "oppi.example.com",
        port: 443,
        scheme: "https",
      });
      expect(readTlsMode(serveDir)).toBe("self-signed");
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  }, 90_000);

  it("doctor on Linux skips the LaunchAgent check instead of aborting on a missing launchctl", () => {
    const linuxDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-linux-"));
    try {
      // A Linux host: no launchd, and any launchctl on PATH fails as "command not found" (127).
      const bin = join(linuxDir, "bin");
      mkdirSync(bin);
      writeFileSync(join(bin, "launchctl"), "#!/bin/sh\nexit 127\n", { mode: 0o755 });
      const { stdout, stderr } = run(["doctor"], {
        OPPI_DATA_DIR: join(linuxDir, "data"),
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        NODE_OPTIONS:
          "--import=data:text/javascript,Object.defineProperty(process,'platform',{value:'linux'})",
      });
      const out = stripAnsi(stdout + stderr);
      expect(out).toContain("Oppi CLI:");
      expect(out).not.toContain("Fatal error");
      expect(out).not.toContain("LaunchAgent");
    } finally {
      rmSync(linuxDir, { recursive: true, force: true });
    }
  });

  it("doctor on a never-served host reports TLS as not chosen, not as disabled", () => {
    const freshDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-fresh-"));
    try {
      const { stdout } = run(["doctor"], { OPPI_DATA_DIR: freshDir });
      const out = stripAnsi(stdout);
      expect(out).toContain("TLS not chosen yet");
      expect(out).not.toContain("TLS disabled while binding");
    } finally {
      rmSync(freshDir, { recursive: true, force: true });
    }
  });

  it("doctor treats publicUrl without trustedPeers as undecided TLS, as the next serve does", () => {
    const publicDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-publicurl-"));
    try {
      writeFileSync(
        join(publicDir, "config.json"),
        JSON.stringify({ host: "0.0.0.0", publicUrl: "https://oppi.example.com" }),
      );
      const { stdout } = run(["doctor"], { OPPI_DATA_DIR: publicDir });
      const out = stripAnsi(stdout);
      expect(out).toContain("TLS not chosen yet");
      expect(out).not.toContain("TLS disabled while binding");
    } finally {
      rmSync(publicDir, { recursive: true, force: true });
    }
  });

  it("doctor keeps the TLS-disabled warning once the host has an owner token", () => {
    const pairedDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-paired-"));
    try {
      writeFileSync(
        join(pairedDir, "config.json"),
        JSON.stringify({ host: "0.0.0.0", token: "sk_doctor_paired", tls: { mode: "disabled" } }),
      );
      const { stdout } = run(["doctor"], { OPPI_DATA_DIR: pairedDir });
      expect(stripAnsi(stdout)).toContain("TLS disabled while binding to 0.0.0.0");
    } finally {
      rmSync(pairedDir, { recursive: true, force: true });
    }
  });
});
