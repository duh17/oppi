import { describe, expect, it } from "vitest";
import { KeyedMutex } from "../src/keyed-mutex.js";

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

async function flush(): Promise<void> {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
}

/** Number of keys the owner still tracks (private state, read only to prove nothing leaks). */
function trackedKeys(mutex: KeyedMutex): number {
  return (mutex as unknown as { entries: Map<string, unknown> })["entries"].size;
}

describe("KeyedMutex", () => {
  it("runs same-key calls one at a time in arrival order", async () => {
    const mutex = new KeyedMutex();
    const order: number[] = [];
    const gate = deferred();

    const first = mutex.withLock("k", async () => {
      await gate.promise;
      order.push(0);
    });
    const rest = Array.from({ length: 20 }, (_, i) =>
      mutex.withLock("k", async () => {
        order.push(i + 1);
      }),
    );
    await flush();
    expect(order).toEqual([]);

    gate.resolve();
    await Promise.all([first, ...rest]);
    expect(order).toEqual(Array.from({ length: 21 }, (_, i) => i));
  });

  it("returns the result and holds no entry once the last holder finishes", async () => {
    const mutex = new KeyedMutex();
    await expect(mutex.withLock("k", async () => 42)).resolves.toBe(42);
    expect(trackedKeys(mutex)).toBe(0);
  });

  it("propagates a rejection, releases the lock for the next waiter, and holds no entry afterwards", async () => {
    const mutex = new KeyedMutex();
    const gate = deferred();
    const events: string[] = [];

    const failing = mutex.withLock("k", async () => {
      await gate.promise;
      events.push("failing");
      throw new Error("boom");
    });
    const failed = expect(failing).rejects.toThrow("boom");
    const next = mutex.withLock("k", async () => {
      events.push("next");
      return "ok";
    });
    expect(trackedKeys(mutex)).toBe(1);

    gate.resolve();
    await failed;
    await expect(next).resolves.toBe("ok");
    expect(events).toEqual(["failing", "next"]);
    expect(trackedKeys(mutex)).toBe(0);
  });

  it("keeps a waiter queued during release exclusive with a later caller", async () => {
    const mutex = new KeyedMutex();
    const gate = deferred();
    let inFlight = 0;
    let peak = 0;
    const critical = async (): Promise<void> => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await flush();
      inFlight -= 1;
    };

    const holder = mutex.withLock("k", async () => {
      await gate.promise;
    });
    const queued = mutex.withLock("k", critical);
    gate.resolve();
    await holder;
    // The holder has released; the queued waiter owns the key. A new caller must wait for it.
    const late = mutex.withLock("k", critical);
    await Promise.all([queued, late]);

    expect(peak).toBe(1);
    expect(trackedKeys(mutex)).toBe(0);
  });
});
