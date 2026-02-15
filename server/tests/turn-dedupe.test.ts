import { describe, expect, it } from "vitest";
import type { ServerMessage } from "../src/types.js";
import { TurnDedupeCache, type TurnDedupeRecord } from "../src/turn-cache.js";

describe("TurnDedupeCache", () => {
  it("stores and returns entries", () => {
    const cache = new TurnDedupeCache(16, 60_000);
    const now = Date.now();

    const record: TurnDedupeRecord = {
      command: "prompt",
      payloadHash: "hash-1",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    };

    cache.set("turn-1", record, now);

    const stored = cache.get("turn-1", now + 1);
    expect(stored).not.toBeNull();
    expect(stored?.command).toBe("prompt");
    expect(stored?.stage).toBe("accepted");
  });

  it("enforces monotonic stage progression", () => {
    const cache = new TurnDedupeCache(16, 60_000);
    const now = Date.now();

    cache.set("turn-1", {
      command: "follow_up",
      payloadHash: "hash-1",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now);

    cache.updateStage("turn-1", "started", now + 1);
    const afterStarted = cache.updateStage("turn-1", "dispatched", now + 2);

    expect(afterStarted?.stage).toBe("started");
  });

  it("expires entries by ttl", () => {
    const cache = new TurnDedupeCache(16, 100);
    const now = Date.now();

    cache.set("turn-1", {
      command: "steer",
      payloadHash: "hash-1",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now);

    expect(cache.get("turn-1", now + 101)).toBeNull();

    cache.set("turn-2", {
      command: "steer",
      payloadHash: "hash-2",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now);

    expect(cache.get("turn-2", now + 50)?.stage).toBe("accepted");
    expect(cache.get("turn-2", now + 149)).not.toBeNull();
    expect(cache.get("turn-2", now + 251)).toBeNull();
  });

  it("evicts the least recently used entry when capacity is exceeded", () => {
    const cache = new TurnDedupeCache(2, 60_000);
    const now = Date.now();

    cache.set("turn-1", {
      command: "prompt",
      payloadHash: "hash-1",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now);

    cache.set("turn-2", {
      command: "prompt",
      payloadHash: "hash-2",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now + 1);

    // Touch turn-1 so turn-2 becomes the LRU candidate.
    cache.get("turn-1", now + 2);

    cache.set("turn-3", {
      command: "prompt",
      payloadHash: "hash-3",
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    }, now + 3);

    expect(cache.get("turn-1", now + 4)).not.toBeNull();
    expect(cache.get("turn-2", now + 4)).toBeNull();
    expect(cache.get("turn-3", now + 4)).not.toBeNull();
  });
});

describe("turn_ack protocol type", () => {
  it("supports staged acknowledgements for clientTurnId", () => {
    const msg: ServerMessage = {
      type: "turn_ack",
      command: "prompt",
      clientTurnId: "turn-123",
      stage: "dispatched",
      requestId: "req-123",
      duplicate: true,
    };

    expect(msg.type).toBe("turn_ack");
    if (msg.type === "turn_ack") {
      expect(msg.stage).toBe("dispatched");
      expect(msg.clientTurnId).toBe("turn-123");
    }
  });
});
