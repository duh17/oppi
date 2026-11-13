/**
 * Surface protocol fixtures — one surface per slice-1 composite, plus the client's capabilities
 * and action messages, the patch, and an unknown-composite surface. Ordinary tests compare the
 * deterministic canonical bytes with the committed files and never rewrite them;
 * `npm run protocol:fixtures:update` is the only writer.
 * The same bytes are decoded by the Apple Codable tests.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { projectExtensionUISurfaceToV1, readExtensionUISurface } from "../src/extension-surface.js";
import { normalizeExtensionUINativeSurface } from "../src/extension-ui-contract.js";
import {
  buildSurfaceFixtures,
  readSurfaceFixture,
  serializeSurfaceFixture,
  SURFACE_FIXTURES_DIR,
} from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();

describe("surface fixtures", () => {
  it("matches every committed fixture byte-for-byte", () => {
    for (const [name, value] of Object.entries(fixtures)) {
      const tracked = readFileSync(resolve(SURFACE_FIXTURES_DIR, name), "utf8");
      expect(tracked, name).toBe(serializeSurfaceFixture(value));
    }
  });

  it("ships one drawable surface per slice-1 composite", () => {
    const composites = ["status-card.json", "checklist.json", "data-table.json", "action-bar.json"];
    for (const name of composites) {
      const read = readExtensionUISurface(readSurfaceFixture(name));
      if ("problem" in read) throw new Error(`${name}: ${read.problem}`);
      const projected = projectExtensionUISurfaceToV1(read.surface);
      expect(normalizeExtensionUINativeSurface(projected), name).toEqual(projected);
    }
  });

  it("keeps a surface's pane hints, and refuses ones the host cannot draw", () => {
    const value = readSurfaceFixture("panel-hints.json") as Record<string, unknown>;
    const read = readExtensionUISurface(value);
    if ("problem" in read) throw new Error(read.problem);
    expect(read.surface.placement.kind).toBe("panel");
    expect(read.surface.panel).toEqual({ icon: "terminal", size: "wide" });
    expect(readExtensionUISurface({ ...value, panel: { icon: "flame" } })).toMatchObject({
      problem: '"flame" is not an allowed icon name',
    });
    expect("problem" in readExtensionUISurface({ ...value, panel: { size: "huge" } })).toBe(true);
    // The working mark is an `icon` node's alone; a pane names a symbol.
    expect(readExtensionUISurface({ ...value, panel: { icon: "working" } })).toMatchObject({
      problem: '"working" is not an allowed icon name',
    });
  });

  it("keeps a widget's pane hints, and drops ones the host cannot draw", () => {
    const value = readSurfaceFixture("native-panel-hints.json") as {
      presentation: Record<string, unknown>;
    };
    expect(normalizeExtensionUINativeSurface(value)?.presentation).toEqual(value.presentation);
    const unknown = { ...value, presentation: { ...value.presentation, icon: "flame", size: 3 } };
    // A classic widget's hint is decoration: the widget still shows, without it.
    expect(normalizeExtensionUINativeSurface(unknown)?.presentation).toEqual({
      style: "surfacePanel",
      title: "Agents",
      subtitle: "1 running",
    });
  });

  it("keeps the unknown-composite fixture undrawable on the server and readable on the phone", () => {
    const surface = readSurfaceFixture("unknown-composite.json") as {
      sections: Array<{ composite: string; fallback: { text: string } }>;
    };
    // The server never publishes it: an unknown composite is refused, not clipped.
    expect("problem" in readExtensionUISurface(surface)).toBe(true);
    // A client still has to read the frame it may one day receive; the labeled fallback text is
    // what it shows for the card it cannot draw.
    expect(surface.sections[1].composite).toBe("logStream");
    expect(surface.sections[1].fallback.text).toContain("Build log");
  });

  it("carries the action and patch messages the runtime sends", () => {
    const action = readSurfaceFixture("action.json") as Record<string, unknown>;
    expect(action).toMatchObject({
      type: "extension_ui_action",
      surfaceId: "deploy",
      compositeId: "status",
      actionId: "retry",
      revision: 7,
    });
    expect(action.values).toEqual({ env: "prod" });

    const patch = readSurfaceFixture("patch.json") as Record<string, unknown>;
    expect(patch).toMatchObject({
      type: "extension_ui_patch",
      surfaceId: "deploy",
      revision: 8,
      sessionId: "test-session-1",
    });
    expect(patch.patch).toEqual({
      "sections.0.state": { kind: "content" },
      "sections.0.phase": "queued",
    });
  });
});
