/**
 * CLI integration tests: unknown command, config, session, wait, status, init, token, and pair.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { describe, expect, it } from "vitest";
import { createServer as createHttpServer } from "node:http";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Storage } from "../src/storage.js";
import { fakeTailscaleEnv } from "./harness/cli-process.js";
import {
  dataDir,
  hasOpenSSL,
  logSkip,
  run,
  runAsync,
  seedConfiguredHost,
  useCliDataDir,
} from "./harness/cli-test-env.js";

useCliDataDir();

// ── Unknown command ──

describe("unknown command", () => {
  it.each(["status", "compat", "finalize"])("rejects removed auth %s command", (action) => {
    const result = run(["auth", action]);
    expect(result.exitCode).toBe(1);
    expect(result.stdout).toContain("Unknown command: auth");
  });
  it("exits 1 with error message", () => {
    const { stdout, exitCode } = run(["bananas"]);
    expect(exitCode).toBe(1);
    expect(stdout).toContain("Unknown command: bananas");
  });
});

// ── Config ──

describe("oppi config", () => {
  function seedConfigDisplaySecrets(): Record<string, string> {
    const secrets = {
      owner: "sk_owner-config-display-secret",
      pairing: "pt_pairing-config-display-secret",
      push: "apns-config-display-secret",
      runtime: "runtime-config-display-secret",
    };
    const storage = new Storage(dataDir);
    storage.updateConfig({
      token: secrets.owner,
      pairingToken: secrets.pairing,
      pushRegistrations: [
        {
          deviceId: "dev_config_display",
          keyId: "config-display-key-id",
          publicKey: "config-display-public-key",
          sendToken: secrets.push,
          registeredAt: 1,
          events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
        },
      ],
      runtimeEnv: { OPENAI_API_KEY: secrets.runtime },
    });
    return secrets;
  }

  it.each(["openai", "openai-codex"])("rejects removed STT provider %s", (provider) => {
    const result = run(["config", "set", "asr.provider", provider]);
    expect(result.exitCode).toBe(1);
    expect(`${result.stdout}${result.stderr}`).toContain("expected http or xai");
  });

  it("config show displays config", () => {
    const { stdout, exitCode } = run(["config", "show"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("port");
  });

  it("config show redacts authentication, device, and runtime secrets", () => {
    const secrets = seedConfigDisplaySecrets();
    const { stdout, exitCode } = run(["config", "show"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"token": "[REDACTED]"');
    expect(stdout).toContain('"pairingToken": "[REDACTED]"');
    expect(stdout).toContain('"pushRegistrations": "[REDACTED 1 push registration]"');
    expect(stdout).toContain('"OPENAI_API_KEY": "[REDACTED]"');
    for (const secret of Object.values(secrets)) expect(stdout).not.toContain(secret);
  });

  it.each([
    "token",
    "pairingToken",
    "pushRegistrations",
    "runtimeEnv.OPENAI_API_KEY",
    "runtimeEnv",
  ])("config get redacts %s", (key) => {
    seedConfigDisplaySecrets();
    const { stdout, exitCode } = run(["config", "get", key]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("[REDACTED");
    expect(stdout).not.toContain("config-display-secret");
  });

  it("config set output and errors never echo runtime secrets", () => {
    const secret = "runtime-set-output-secret";
    const success = run(["config", "set", "runtimeEnv.OPENAI_API_KEY", secret]);
    const invalid = run(["config", "set", "runtimeEnv", `{not-json:${secret}}`]);
    const listing = run(["config", "set"]);
    expect(success.exitCode).toBe(0);
    expect(success.stdout).toContain("[REDACTED]");
    expect(success.stdout).not.toContain(secret);
    expect(invalid.exitCode).toBe(1);
    expect(invalid.stdout).not.toContain(secret);
    expect(listing.exitCode).toBe(1);
    expect(listing.stdout).not.toContain(secret);
  });

  // 10 sequential CLI spawns run ~6s locally but exceed the 10s default under
  // loaded coverage CI runners; each run() already caps a single spawn at 15s.
  it("config set/get roundtrips values", () => {
    run(["config", "set", "port", "9999"]);
    expect(run(["config", "get", "port"]).stdout.trim()).toContain("9999");
    run(["config", "set", "extensions", '{"voice":{"defaultVoiceId":"warm"}}']);
    expect(run(["config", "get", "extensions"]).stdout.trim()).toContain(
      '"defaultVoiceId": "warm"',
    );
    run(["config", "set", "asr.sttEndpoint", "http://127.0.0.1:7936"]);
    expect(run(["config", "get", "asr.sttEndpoint"]).stdout.trim()).toBe("http://127.0.0.1:7936");
    run(["config", "set", "asr.provider", "xai"]);
    expect(run(["config", "get", "asr.provider"]).stdout.trim()).toBe("xai");
    run(["config", "set", "asr.sttModel", "yuwp-model"]);
    expect(run(["config", "get", "asr.sttModel"]).stdout.trim()).toBe("yuwp-model");
    const setExtension = run(["config", "set", "asr.extension", "@earendil-works/pi-transcribe"]);
    expect(setExtension.exitCode).toBe(1);
    expect(`${setExtension.stdout}${setExtension.stderr}`).toContain("Unknown config key");
    const setBackend = run(["config", "set", "asr.backend", "pi-extension"]);
    expect(setBackend.exitCode).toBe(1);
    expect(`${setBackend.stdout}${setBackend.stderr}`).toContain("expected http");
    expect(run(["config", "get", "asr.backend"]).exitCode).toBe(1);
    expect(run(["config", "get", "asr.sttEndpoint"]).stdout.trim()).toBe("http://127.0.0.1:7936");
    run(["config", "set", "oppiDocsPrompt.enabled", "false"]);
    expect(run(["config", "get", "oppiDocsPrompt.enabled"]).stdout.trim()).toBe("false");
    run(["config", "set", "runtimeEnv.TTS_BASE_URL", "http://127.0.0.1:7937"]);
    expect(run(["config", "get", "runtimeEnv.TTS_BASE_URL"]).stdout.trim()).toBe(
      "http://127.0.0.1:7937",
    );
  }, 45_000);

  it("config validate succeeds on valid config", () => {
    const { stdout, exitCode } = run(["config", "validate"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Config valid");
  });

  it("config validate detects invalid config file", () => {
    const badConfig = join(dataDir, "bad-config.json");
    writeFileSync(badConfig, '{ "port": "not-a-number" }');
    const { stdout } = run(["config", "validate", "--config-file", badConfig]);
    expect(stdout.length).toBeGreaterThan(0);
  });
});

// ── Session ──

describe("oppi session", () => {
  it("session create --json reports missing required flags in a stable envelope", () => {
    const { stdout, exitCode } = run(["session", "create", "--json"]);
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "--workspace and --prompt are required" },
    });
  });
});

// ── Wait ──

describe("oppi wait", () => {
  it("rejects a zero poll interval before polling the local API", () => {
    const { stdout, exitCode } = run(["wait", "session", "sess-1", "--poll", "0ms", "--json"]);
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "--poll must be a positive duration" },
    });
  });
});

// ── Local orchestration authorization ──

describe("local orchestration prerequisites", () => {
  it("requires local owner credentials before calling orchestration APIs", () => {
    const freshDir = mkdtempSync(join(tmpdir(), "oppi-cli-no-owner-"));
    try {
      const { stdout, exitCode } = run(["workspace", "list", "--json"], {
        OPPI_DATA_DIR: freshDir,
      });
      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toEqual({
        ok: false,
        error: {
          message: "No owner Bearer [REDACTED] configured. Run 'oppi init' or 'oppi pair' first.",
        },
      });
    } finally {
      rmSync(freshDir, { recursive: true, force: true });
    }
  });

  it("requires a running local server after setup", async () => {
    const configuredDir = mkdtempSync(join(tmpdir(), "oppi-cli-server-required-"));
    try {
      seedConfiguredHost(configuredDir);

      const { stdout, exitCode } = await runAsync(["workspace", "list", "--json"], {
        OPPI_DATA_DIR: configuredDir,
      });
      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout).error.message).toMatch(/ECONNREFUSED|connect/i);
    } finally {
      rmSync(configuredDir, { recursive: true, force: true });
    }
  });
});

// ── Status ──

describe("oppi status", () => {
  it("prints status info", () => {
    const { stdout, exitCode } = run(["status"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Server Configuration");
  });
});

// ── Init ──

describe("oppi init", () => {
  it("re-init releases the relay permissions of the push registrations it drops", async () => {
    const initDir = mkdtempSync(join(tmpdir(), "oppi-cli-init-push-"));
    const released: string[] = [];
    const relay = createHttpServer((req, res) => {
      if (req.method === "DELETE" && req.url === "/v1/permission") {
        released.push(req.headers.authorization ?? "");
        res.writeHead(204).end();
        return;
      }
      res.writeHead(404).end();
    });
    await new Promise<void>((resolveListen) => relay.listen(0, "127.0.0.1", resolveListen));
    const { port } = relay.address() as { port: number };

    try {
      expect(run(["init", "--yes", "--data-dir", initDir]).exitCode).toBe(0);
      const registration = (deviceId: string) => ({
        deviceId,
        keyId: `kid-${deviceId}`,
        publicKey: "AAAA",
        sendToken: `send-${deviceId}`,
        registeredAt: 1,
        events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
      });
      new Storage(initDir).updateConfig({
        push: { mode: "relay", relays: [`http://127.0.0.1:${port}`] },
        pushRegistrations: [registration("phone"), registration("ipad")],
      });

      const { stdout, exitCode } = await runAsync([
        "init",
        "--yes",
        "--force",
        "--data-dir",
        initDir,
      ]);

      expect(exitCode).toBe(0);
      expect(released.sort()).toEqual(["Bearer send-ipad", "Bearer send-phone"]);
      expect(stdout).toContain("Released 2 push permission(s)");
      expect(new Storage(initDir).getConfig().pushRegistrations ?? []).toEqual([]);
    } finally {
      await new Promise((resolveClose) => relay.close(resolveClose));
      rmSync(initDir, { recursive: true, force: true });
    }
  });
});

// ── Token ──

describe("oppi token", () => {
  it("token rotate fails before pairing", () => {
    const freshDir = mkdtempSync(join(tmpdir(), "oppi-cli-token-"));
    const { exitCode } = run(["token", "rotate"], { OPPI_DATA_DIR: freshDir });
    expect(exitCode).toBe(1);
    rmSync(freshDir, { recursive: true, force: true });
  });

  it("token rotate requires a running server (no file-based fallback)", () => {
    // Pair first to create the owner token.
    run(["pair"]);
    const before = new Storage(dataDir).getToken();

    // Rotation now mutates the live server via the owner-only Unix socket.
    const { stdout, exitCode } = run(["token", "rotate"]);
    expect(exitCode).toBe(1);
    expect(stdout).toContain("could not rotate");

    // No stale file-based mutation when the server is absent.
    const after = new Storage(dataDir).getToken();
    expect(after).toBe(before);
  });
});

// ── Pair ──

describe("oppi pair", () => {
  it("generates QR code output", () => {
    const { stdout, exitCode } = run(["pair"]);
    // Pair should succeed or at least output something
    // Host auto-detection may vary by environment but should still output
    expect(exitCode).toBe(0);
    // Should contain QR blocks or URL
    expect(stdout.length).toBeGreaterThan(50);
  });

  it("honors --ttl for the enforced deadline and keeps the outstanding invite on a rejected --ttl", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-pair-ttl-"));
    const env = { OPPI_DATA_DIR: dataDir };
    const readPairing = () =>
      JSON.parse(readFileSync(join(dataDir, "config.json"), "utf-8")) as {
        pairingToken?: string;
        pairingTokenExpiresAt?: number;
      };
    const pairJson = (...extra: string[]) => {
      const before = Date.now();
      const result = run(["pair", "--host", "127.0.0.1", "--json", ...extra], env);
      expect(result.exitCode).toBe(0);
      const invite = JSON.parse(result.stdout) as { pairingToken: string; expiresAt: string };
      return { invite, lifetimeMs: Date.parse(invite.expiresAt) - before };
    };

    try {
      const fallback = pairJson();
      expect(fallback.lifetimeMs).toBeGreaterThanOrEqual(90_000);
      expect(fallback.lifetimeMs).toBeLessThan(90_000 + 10_000);

      const review = pairJson("--ttl", "14d");
      const fourteenDaysMs = 14 * 86_400_000;
      expect(review.lifetimeMs).toBeGreaterThanOrEqual(fourteenDaysMs);
      expect(review.lifetimeMs).toBeLessThan(fourteenDaysMs + 10_000);
      // Printed expiry must be the deadline pairing actually enforces.
      expect(readPairing()).toMatchObject({
        pairingToken: review.invite.pairingToken,
        pairingTokenExpiresAt: Date.parse(review.invite.expiresAt),
      });

      // Bounds are inclusive: 1s and 30d issue, anything else exits 1 before a token is written.
      const accepted: Array<[string, number]> = [
        ["1s", 1_000],
        ["1000ms", 1_000],
        ["30d", 30 * 86_400_000],
      ];
      for (const [ttl, expectedMs] of accepted) {
        const issued = pairJson("--ttl", ttl);
        expect(issued.lifetimeMs, ttl).toBeGreaterThanOrEqual(expectedMs);
        expect(issued.lifetimeMs, ttl).toBeLessThan(expectedMs + 10_000);
        expect(readPairing().pairingToken).toBe(issued.invite.pairingToken);
      }

      const outstanding = pairJson("--ttl", "14d").invite.pairingToken;
      const rejectedArgs = [
        ["--ttl", "31d"],
        ["--ttl", "500ms"],
        ["--ttl", "0"],
        ["--ttl", "-1d"],
        ["--ttl", "NaN"],
        ["--ttl", "1.5d"],
        ["--ttl", "soon"],
        ["--ttl", "99999999999999999999d"],
        ["--ttl"],
        // parseCliArgs does not split `=`; this must not fall back to a 90s invite.
        ["--ttl=14d"],
      ];
      for (const extra of rejectedArgs) {
        const rejected = run(["pair", "--host", "127.0.0.1", "--json", ...extra], env);
        expect(rejected.exitCode, extra.join(" ")).toBe(1);
        expect(rejected.stdout).toBe("");
        // A typo must not silently replace the invite already handed out.
        expect(readPairing().pairingToken, extra.join(" ")).toBe(outstanding);
      }
      const rangeError = run(["pair", "--host", "127.0.0.1", "--json", "--ttl", "500ms"], env);
      expect(rangeError.stderr).toContain("1s to 30d");
      expect(rangeError.stderr).not.toContain("500ms, 15s");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 60_000);
});

describe.skipIf(
  logSkip(!hasOpenSSL, "oppi pair (tls self-signed)", "openssl executable is unavailable"),
)("oppi pair (tls self-signed)", () => {
  it("embeds https scheme + cert fingerprint in invite payload", () => {
    const tlsDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-pair-tls-"));

    try {
      const setResult = run(["config", "set", "tls", '{"mode":"self-signed"}'], {
        OPPI_DATA_DIR: tlsDataDir,
      });
      expect(setResult.exitCode).toBe(0);

      const { stdout, exitCode } = run(["pair", "--host", "127.0.0.1"], {
        OPPI_DATA_DIR: tlsDataDir,
      });
      expect(exitCode).toBe(0);

      const stripped = stdout.replace(/\x1b\[[0-9;]*m/g, "");
      const link = stripped.match(/oppi:\/\/connect\?[^\s]+/);
      expect(link).not.toBeNull();

      const url = new URL(link![0]);
      const invite = url.searchParams.get("invite");
      expect(invite).toBeTruthy();

      const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
        signedPayload?: string;
        publicKey?: string;
        signature?: string;
      };
      expect(envelope.publicKey).toBeTruthy();
      expect(envelope.signature).toBeTruthy();
      const payload = JSON.parse(
        Buffer.from(envelope.signedPayload!, "base64url").toString("utf-8"),
      ) as {
        scheme?: string;
        tlsCertFingerprint?: string;
      };

      expect(payload.scheme).toBe("https");
      expect(payload.tlsCertFingerprint?.startsWith("sha256:")).toBe(true);
    } finally {
      rmSync(tlsDataDir, { recursive: true, force: true });
    }
  });
});

describe.skipIf(
  logSkip(!hasOpenSSL, "oppi pair (tls tailscale)", "openssl executable is unavailable"),
)("oppi pair (tls tailscale)", () => {
  it("uses a Tailnet SAN for pairing and recovers it after Tailscale stops", () => {
    const tlsDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-pair-tailscale-"));
    const fakeBinDir = mkdtempSync(join(tmpdir(), "oppi-cli-fake-tailscale-"));
    const fakeTailscalePath = join(fakeBinDir, "tailscale");

    writeFileSync(
      fakeTailscalePath,
      `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
if [[ -z "\$cmd" ]]; then
  exit 1
fi
shift || true

case "\$cmd" in
  status)
    if [[ "\${1:-}" == "--json" ]]; then
      echo '{"Self":{"DNSName":"my-server.tail00000.ts.net."}}'
      exit 0
    fi
    ;;
  cert)
    cert_file=""
    key_file=""
    host=""

    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --cert-file)
          cert_file="\$2"
          shift 2
          ;;
        --key-file)
          key_file="\$2"
          shift 2
          ;;
        --min-validity)
          shift 2
          ;;
        *)
          host="\$1"
          shift
          ;;
      esac
    done

    if [[ -z "\$cert_file" || -z "\$key_file" || -z "\$host" ]]; then
      echo "missing cert args" >&2
      exit 1
    fi

    mkdir -p "\$(dirname "\$cert_file")" "\$(dirname "\$key_file")"
    openssl req -x509 -newkey rsa:2048 -nodes \\
      -keyout "\$key_file" \\
      -out "\$cert_file" \\
      -subj "/CN=\$host" \\
      -addext "subjectAltName=DNS:\$host" \\
      -days 1 >/dev/null 2>&1
    exit 0
    ;;
esac

echo "unsupported args: \$cmd \$*" >&2
exit 1
`,
      { mode: 0o755 },
    );
    chmodSync(fakeTailscalePath, 0o755);

    const env = {
      OPPI_DATA_DIR: tlsDataDir,
      ...fakeTailscaleEnv(fakeTailscalePath),
    };

    try {
      const setResult = run(["config", "set", "tls", '{"mode":"tailscale"}'], env);
      expect(setResult.exitCode).toBe(0);

      const { stdout, exitCode } = run(["pair"], env);
      expect(exitCode).toBe(0);

      const stripped = stdout.replace(/\x1b\[[0-9;]*m/g, "");
      const link = stripped.match(/oppi:\/\/connect\?[^\s]+/);
      expect(link).not.toBeNull();

      const url = new URL(link![0]);
      const invite = url.searchParams.get("invite");
      expect(invite).toBeTruthy();

      const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
        signedPayload?: string;
        publicKey?: string;
        signature?: string;
      };
      expect(envelope.publicKey).toBeTruthy();
      expect(envelope.signature).toBeTruthy();
      const payload = JSON.parse(
        Buffer.from(envelope.signedPayload!, "base64url").toString("utf-8"),
      ) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };

      expect(payload.host).toBe("my-server.tail00000.ts.net");
      expect(payload.scheme).toBe("https");
      expect(payload.tlsCertFingerprint).toBeUndefined();

      // The live daemon is no longer discoverable. Pairing must recover the
      // hostname from the existing valid leaf SAN and must not need renewal.
      writeFileSync(fakeTailscalePath, "#!/usr/bin/env bash\nexit 1\n", { mode: 0o755 });
      const stoppedResult = run(["pair", "--json"], env);
      expect(stoppedResult.exitCode).toBe(0);
      const stoppedInvite = JSON.parse(stoppedResult.stdout) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };
      expect(stoppedInvite.host).toBe("my-server.tail00000.ts.net");
      expect(stoppedInvite.scheme).toBe("https");
      expect(stoppedInvite.tlsCertFingerprint).toBeUndefined();
    } finally {
      rmSync(tlsDataDir, { recursive: true, force: true });
      rmSync(fakeBinDir, { recursive: true, force: true });
    }
  });
});
