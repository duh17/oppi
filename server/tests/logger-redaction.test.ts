import { describe, expect, it } from "vitest";

import { createLogger } from "../src/logger.js";
import { redactLogString, redactLogValue } from "../src/log-redact.js";

describe("logger", () => {
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
        password: "dont-log-me",
        command: "curl https://api.example.com?token=sk_live_ABCDEF1234",
      },
    });

    expect(lines).toHaveLength(1);

    const raw = lines[0];
    expect(raw).not.toContain("sk_live_SUPER_SECRET_123456");
    expect(raw).not.toContain("ghp_SUPER_SECRET_abcdefghijklmnopqrstuvwxyz");
    expect(raw).not.toContain("dont-log-me");

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

  it("redacts bearer and private key strings", () => {
    const input =
      "Authorization: Bearer sk_live_abc123 -----BEGIN PRIVATE KEY-----abc-----END PRIVATE KEY-----";

    const redacted = redactLogString(input, 4_096);
    expect(redacted).toContain("Bearer [REDACTED]");
    expect(redacted).toContain("[REDACTED_PRIVATE_KEY]");
    expect(redacted).not.toContain("sk_live_abc123");
  });
});
