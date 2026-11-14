import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { GODOT_SNAPSHOT_FILE, serializeGodotFixture } from "./godot-fixtures.js";

describe("game protocol fixture", () => {
  it("matches the committed protocol/godot.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializeGodotFixture()).toBe(readFileSync(GODOT_SNAPSHOT_FILE, "utf8"));
  });
});
