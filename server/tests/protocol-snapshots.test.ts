/**
 * Protocol snapshot tests — canonical JSON for every ServerMessage discriminator.
 *
 * Ordinary tests compare the deterministic in-memory canonical bytes with the
 * committed fixture. They never rewrite tracked JSON. Use the explicit update
 * command when a deliberate protocol fixture change is intended.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Session } from "../src/types.js";
import {
  assertNoOverlappingFixtureKeys,
  assertProtocolFixtureBytes,
  buildCanonicalServerMessages,
  SERVER_MESSAGES_FIXTURE_DESCRIPTION,
  SERVER_MESSAGES_SNAPSHOT_FILE,
  serializeProtocolFixture,
} from "./protocol-fixtures.js";

const messages = buildCanonicalServerMessages();
const expectedSnapshot = serializeProtocolFixture(SERVER_MESSAGES_FIXTURE_DESCRIPTION, messages);

describe("protocol snapshots", () => {
  it("reports canonical drift without writing tracked fixtures", () => {
    const tracked = readFileSync(SERVER_MESSAGES_SNAPSHOT_FILE, "utf-8");
    const drifted = tracked.replace('"type": "connected"', '"type": "connected!"');

    expect(drifted).not.toBe(tracked);
    expect(() => assertProtocolFixtureBytes("server-messages.json", tracked, drifted)).toThrow(
      /server-messages\.json at byte \d+/,
    );
    expect(readFileSync(SERVER_MESSAGES_SNAPSHOT_FILE, "utf-8")).toBe(tracked);
  });

  it("matches the committed ServerMessage fixture byte-for-byte", () => {
    const tracked = readFileSync(SERVER_MESSAGES_SNAPSHOT_FILE, "utf-8");

    expect(() =>
      assertProtocolFixtureBytes("server-messages.json", expectedSnapshot, tracked),
    ).not.toThrow();

    const parsed = JSON.parse(tracked) as { messages?: Record<string, unknown> };
    expect(parsed.messages).toBeDefined();
    expect(Object.keys(parsed.messages ?? {})).toHaveLength(Object.keys(messages).length);
  });

  it("keeps examples typed and rejects temporary compatibility key collisions", () => {
    for (const [key, message] of Object.entries(messages)) {
      const type = (message as { type?: unknown }).type;
      expect(type, `Message "${key}" missing type`).toBeTypeOf("string");
    }

    const temporaryCollisions = [
      ["server-messages.json", "connected"],
      ["app-event-messages.json", "app_events_connected"],
    ] as const;
    for (const [fixtureName, key] of temporaryCollisions) {
      expect(() =>
        assertNoOverlappingFixtureKeys(
          fixtureName,
          { [key]: { type: key } },
          { [key]: { type: key } },
        ),
      ).toThrow(
        `${fixtureName} has compatibility keys that shadow typed canonical keys: ${key}`,
      );
    }
  });

  it("session objects have all required fields", () => {
    const sessionMessages = Object.values(messages).filter(
      (message): message is { session: Session } =>
        typeof message === "object" && message !== null && "session" in message,
    );

    for (const { session } of sessionMessages) {
      expect(session.id).toBeTypeOf("string");
      expect(session.status).toBeTypeOf("string");
      expect(session.createdAt).toBeTypeOf("number");
      expect(session.lastActivity).toBeTypeOf("number");
      expect(session.messageCount).toBeTypeOf("number");
      expect(session.tokens).toBeDefined();
      expect(session.tokens.input).toBeTypeOf("number");
      expect(session.tokens.output).toBeTypeOf("number");
      expect(session.tokens.cacheRead).toBeTypeOf("number");
      expect(session.tokens.cacheWrite).toBeTypeOf("number");
      expect(session.cost).toBeTypeOf("number");
    }
  });

  it("timestamps are Unix milliseconds (not seconds)", () => {
    const connected = messages.connected as { session: Session };

    expect(connected.session.createdAt).toBeGreaterThan(1e12);
    expect(connected.session.lastActivity).toBeGreaterThan(1e12);
  });
});
