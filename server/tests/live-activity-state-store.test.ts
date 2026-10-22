import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  FileLiveActivityStateStore,
  liveActivityStatePath,
} from "../src/live-activity-state-store.js";

describe("FileLiveActivityStateStore", () => {
  let dir: string;
  let path: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "live-activity-state-"));
    path = liveActivityStatePath(dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("gives back the cards it saved, and leaves no temporary file behind", () => {
    const store = new FileLiveActivityStateStore(path);
    store.save(
      new Map([
        ["d_a", { activity: "live", startedAt: 1_000 }],
        ["d_b", { activity: "unknown", startedAt: 2_000 }],
      ]),
    );
    store.save(new Map([["d_a", { activity: "live", startedAt: 3_000 }]]));
    expect(new FileLiveActivityStateStore(path).load()).toEqual(
      new Map([["d_a", { activity: "live", startedAt: 3_000 }]]),
    );
    expect(readdirSync(dir)).toEqual(["live-activity-state.json"]);
  });

  it("falls back to no cards for a missing, corrupt, or foreign file", () => {
    const store = new FileLiveActivityStateStore(path);
    expect(store.load()).toEqual(new Map());
    for (const content of [
      "{not json",
      "",
      "null",
      "[]",
      JSON.stringify({ version: 2, cards: {} }),
      JSON.stringify({ version: 1, cards: [] }),
    ]) {
      writeFileSync(path, content);
      expect(store.load()).toEqual(new Map());
    }
  });

  it("drops entries that are not a card and keeps the rest", () => {
    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        cards: {
          d_ok: { activity: "live", startedAt: 5 },
          d_none: { activity: "none", startedAt: 5 },
          d_nan: { activity: "live", startedAt: "5" },
          d_null: null,
        },
      }),
    );
    expect(new FileLiveActivityStateStore(path).load()).toEqual(
      new Map([["d_ok", { activity: "live", startedAt: 5 }]]),
    );
  });
});
