import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { checkScreenPage } from "../src/plugin-screens.js";
import {
  buildScreensFixture,
  SCREENS_SNAPSHOT_FILE,
  serializeScreensFixture,
} from "./screens-fixtures.js";

describe("plugin screens protocol fixture", () => {
  it("matches the committed protocol/screens.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializeScreensFixture()).toBe(readFileSync(SCREENS_SNAPSHOT_FILE, "utf8"));
  });

  it("holds the plugin pages the stream would send, with every row kind", () => {
    const { pages } = buildScreensFixture();
    for (const [name, page] of Object.entries(pages))
      expect([name, checkScreenPage(page)]).toEqual([name, undefined]);
    const kinds = new Set(
      Object.values(pages).flatMap((page) =>
        page.sections.flatMap((s) => s.rows.map((r) => r.kind)),
      ),
    );
    expect([...kinds].sort()).toEqual([
      "button",
      "choice",
      "field",
      "item",
      "text",
      "toggle",
      "value",
    ]);
  });
});
