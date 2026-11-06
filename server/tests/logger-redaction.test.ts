import { afterEach, describe, expect, it, vi } from "vitest";

import { createLogger } from "../src/logger.js";
import { isSensitiveLogKey, redactLogString, redactLogValue } from "../src/log-redact.js";

describe("logger", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("redacts secret-looking keys and values before writing logs", () => {
    const lines: string[] = [];
    const logger = createLogger({
      level: "debug",
      now: () => "2026-04-22T00:00:00.000Z",
      sink: (_level, line) => lines.push(line),
      base: { component: "test" },
    });

    logger.info("ws.command", {
      authorization: "Bearer sk_live_SUPER_SECRET_123456",
      requestId: "req-1",
      nested: {
        apiKey: "ghp_SUPER_SECRET_abcdefghijklmnopqrstuvwxyz",
        accessToken: "plain-token-that-does-not-match-value-regex",
        password: "dont-log-me",
        command: "curl https://api.example.com?token=sk_live_ABCDEF1234",
      },
    });

    expect(lines).toHaveLength(1);

    const raw = lines[0];
    expect(raw).not.toContain("sk_live_SUPER_SECRET_123456");
    expect(raw).not.toContain("ghp_SUPER_SECRET_abcdefghijklmnopqrstuvwxyz");
    expect(raw).not.toContain("dont-log-me");
    expect(raw).not.toContain("plain-token-that-does-not-match-value-regex");

    const parsed = JSON.parse(raw) as {
      ts: string;
      level: string;
      event: string;
      authorization: string;
      nested: Record<string, unknown>;
    };

    expect(parsed.ts).toBe("2026-04-22T00:00:00.000Z");
    expect(parsed.level).toBe("info");
    expect(parsed.event).toBe("ws.command");
    expect(parsed.authorization).toBe("[REDACTED]");
    expect(parsed.nested.apiKey).toBe("[REDACTED]");
    expect(parsed.nested.accessToken).toBe("[REDACTED]");
    expect(parsed.nested.password).toBe("[REDACTED]");
    expect(parsed.nested.command).toBe("curl https://api.example.com?token=[REDACTED]");
  });

  it("drops debug logs when level is info", () => {
    const lines: string[] = [];
    const logger = createLogger({
      level: "info",
      sink: (_level, line) => lines.push(line),
    });

    logger.debug("debug.event", { value: 1 });

    expect(lines).toHaveLength(0);
  });

  it("writes default log output to stderr so CLI stdout stays machine-readable", () => {
    const stdout = vi.spyOn(process.stdout, "write").mockReturnValue(true);
    const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
    const logger = createLogger({
      level: "info",
      now: () => "2026-04-22T00:00:00.000Z",
    });

    logger.info("cli.noise", { value: 1 });

    expect(stdout).not.toHaveBeenCalled();
    expect(stderr).toHaveBeenCalledTimes(1);
    expect(String(stderr.mock.calls[0]?.[0])).toContain('"event":"cli.noise"');
  });
});

describe("log-redact", () => {
  it("handles circular objects and sensitive keys", () => {
    const obj: Record<string, unknown> = {
      token: "secret-token",
      child: {
        cookie: "foo=bar",
      },
    };
    obj.self = obj;

    const redacted = redactLogValue(obj) as Record<string, unknown>;
    expect(redacted.token).toBe("[REDACTED]");
    expect((redacted.child as Record<string, unknown>).cookie).toBe("[REDACTED]");
    expect(redacted.self).toBe("[CIRCULAR]");
  });

  it("detects credential and stable device identifier keys without hiding token counters", () => {
    expect(isSensitiveLogKey("accessToken")).toBe(true);
    expect(isSensitiveLogKey("openaiApiKey")).toBe(true);
    expect(isSensitiveLogKey("authDeviceTokens")).toBe(true);
    expect(isSensitiveLogKey("deviceId")).toBe(true);
    expect(isSensitiveLogKey("device")).toBe(true);
    expect(isSensitiveLogKey("tokenCount")).toBe(false);
    expect(isSensitiveLogKey("authPresent")).toBe(false);
  });

  it("redacts bearer and private key strings", () => {
    const input =
      "Authorization: Bearer sk_live_abc123 -----BEGIN PRIVATE KEY-----abc-----END PRIVATE KEY-----";

    const redacted = redactLogString(input, 4_096);
    expect(redacted).toContain("Bearer [REDACTED]");
    expect(redacted).toContain("[REDACTED_PRIVATE_KEY]");
    expect(redacted).not.toContain("sk_live_abc123");
  });

  it("redacts Oppi owner, pairing, and device bearer prefixes in free-form logs", () => {
    const input = [
      "sk_owner-log-fixture-secret",
      "pt_pairing-log-fixture-secret",
      "dt_device-log-fixture-secret",
    ].join(" ");

    const redacted = redactLogString(input, 4_096);
    expect(redacted).toBe("[REDACTED] [REDACTED] [REDACTED]");
  });

  // Fake keys are assembled at runtime so secret scanners do not flag this file.
  const tail = (n: number) => "Ab3dEf9h".repeat(Math.ceil(n / 8)).slice(0, n);
  const keyShapes: Record<string, string> = {
    anthropic: ["sk", "ant", `api03-${tail(40)}`].join("-"),
    project: ["sk", "proj", tail(40)].join("-"),
    serviceAccount: ["sk", "svcacct", tail(40)].join("-"),
    admin: ["sk", "admin", tail(40)].join("-"),
    legacy: `sk-${tail(48)}`,
  };

  for (const [name, key] of Object.entries(keyShapes)) {
    it(`redacts ${name} keys standing alone, glued to a word, and after Bearer`, () => {
      expect(redactLogString(`upstream said key=${key} rejected`, 4_096)).toBe(
        "upstream said key=[REDACTED] rejected",
      );
      expect(redactLogString(`token=${key}`, 4_096)).toBe("token=[REDACTED]");
      expect(redactLogString(`{"key${key}"}`, 4_096)).toBe('{"key[REDACTED]"}');
      expect(redactLogString(`Bearer${key}`, 4_096)).toBe("Bearer[REDACTED]");
      expect(redactLogString(`Authorization: Bearer ${key}`, 4_096)).toBe(
        "Authorization: Bearer [REDACTED]",
      );
    });
  }

  it("leaves near-miss non-secrets alone", () => {
    const inputs = [
      "run the task-sk- prefix check",
      "sk-learn and sk-short words",
      "desk-admin-console and disk-ant-farmhouse settings",
      "task-sk-proj-ects",
      "commit 3f786850e387550fdab836ed7e6dc881de23001b merged",
      "request 123e4567-e89b-12d3-a456-426614174000 done",
      "sk-Ab3dEf9hAb3d",
      "git checkout task-proj-1234-fix-login-redirect",
      "pod flask-admin-deployment-7d9f8c6b5-x2k4p restarted",
      "kiosk-admin-123e4567-e89b-12d3-a456-426614174000",
    ];
    for (const input of inputs) expect(redactLogString(input, 4_096)).toBe(input);
  });

  it("scans a 1 MB run of key-prefix near-misses in linear time", () => {
    // A quadratic scan of this input takes about a minute and times the test out.
    const cases: Array<[string, string]> = [
      ["xsk-proj-", "xsk-proj-"],
      ["-----BEGIN RSA PRIVATE KEY-----\n", "[REDACTED_PRIVATE_KEY]\n"],
    ];
    for (const [unit, expected] of cases) {
      const count = Math.ceil(1_048_576 / unit.length);
      const input = unit.repeat(count);
      expect(redactLogString(input, input.length * 2)).toBe(expected.repeat(count));
    }
  });

  it("redacts encoded oppi://connect invites", () => {
    const input = "invite oppi://connect?v=3&invite=abc.def.ghi host=mac-studio.ts.net";
    const redacted = redactLogString(input, 4_096);
    expect(redacted).toContain("oppi://connect?[REDACTED]");
    expect(redacted).not.toContain("invite=abc.def.ghi");
  });
});
