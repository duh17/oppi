import { describe, expect, it } from "vitest";

import {
  applyExtensionUISurfacePatch,
  projectExtensionUISurfaceToV1,
  readExtensionUISurface,
  EXTENSION_UI_SURFACE_MAX_ACTIONS,
  EXTENSION_UI_SURFACE_MAX_ATOMS,
  EXTENSION_UI_SURFACE_MAX_BYTES,
  EXTENSION_UI_SURFACE_MAX_CELL_CHARS,
  EXTENSION_UI_SURFACE_MAX_COLUMNS,
  EXTENSION_UI_SURFACE_MAX_ITEMS,
  EXTENSION_UI_SURFACE_MAX_SECTIONS,
  EXTENSION_UI_SURFACE_MAX_SPANS,
} from "../src/extension-surface.js";
import { normalizeExtensionUINativeSurface } from "../src/extension-ui-contract.js";
import type { ExtensionUISurface } from "../src/types.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();

/** The canonical surface, or `undefined` when the host refused it. */
function surfaceOf(value: unknown): ExtensionUISurface | undefined {
  const read = readExtensionUISurface(value);
  return "problem" in read ? undefined : read.surface;
}

/** The rule the host refused the surface by. */
function problemOf(value: unknown): string | undefined {
  const read = readExtensionUISurface(value);
  return "problem" in read ? read.problem : undefined;
}

function validSurface(): Record<string, unknown> {
  return JSON.parse(JSON.stringify(fixtures["status-card.json"])) as Record<string, unknown>;
}

function tableSurface(): Record<string, unknown> {
  return JSON.parse(JSON.stringify(fixtures["data-table.json"])) as Record<string, unknown>;
}

function sectionOf(surface: Record<string, unknown>, index = 0): Record<string, unknown> {
  return (surface.sections as Record<string, unknown>[])[index];
}

describe("extension surface validation", () => {
  it("accepts one fixture surface per composite", () => {
    for (const name of [
      "status-card.json",
      "checklist.json",
      "data-table.json",
      "action-bar.json",
    ]) {
      const surface = surfaceOf(fixtures[name]);
      expect(surface, name).toBeDefined();
      expect(surface?.version).toBe(2);
    }
  });

  it("drops a composite an atom tries to carry instead of drawing it", () => {
    const surface = validSurface();
    const steps = sectionOf(surface).steps as Record<string, unknown>[];
    steps[1].extra = [
      { type: "text", spans: [{ text: "ok" }], sections: [{ composite: "checklist" }] },
    ];
    // Unknown properties inside an atom are not rendered, but the shape still refuses the value.
    expect(problemOf(surface)).toBeUndefined();
    const atoms = (
      surfaceOf(surface)?.sections[0] as { steps?: Array<{ extra?: unknown[] }> }
    ).steps?.[1].extra;
    expect(JSON.stringify(atoms)).not.toContain("checklist");
  });

  // Every cap refuses its bad case rather than clipping, so an author learns the limit.
  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_SECTIONS} sections`, () => {
    const surface = validSurface();
    const section = sectionOf(surface);
    surface.sections = Array.from(
      { length: EXTENSION_UI_SURFACE_MAX_SECTIONS + 1 },
      (_, index) => ({
        ...section,
        id: `status-${index}`,
      }),
    );
    expect(surfaceOf(surface)).toBeUndefined();
    expect(problemOf(surface)).toMatch(/sections/);
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ITEMS} rows`, () => {
    const surface = tableSurface();
    const section = sectionOf(surface) as { columns: Array<{ id: string }> };
    surface.sections = [
      {
        ...sectionOf(surface),
        rows: Array.from({ length: EXTENSION_UI_SURFACE_MAX_ITEMS + 1 }, (_, index) => ({
          id: `row-${index}`,
          cells: { [section.columns[0].id]: `value ${index}` },
        })),
      },
    ];
    expect(surfaceOf(surface)).toBeUndefined();
    expect(problemOf(surface)).toMatch(/rows/);
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ACTIONS} actions in the action table`, () => {
    const surface = validSurface();
    const table = surface.actions as Record<string, unknown>;
    for (let index = 0; index < EXTENSION_UI_SURFACE_MAX_ACTIONS; index += 1)
      table[`extra${index}`] = { title: `Extra ${index}` };
    expect(problemOf(surface)).toMatch(/action table exceeds/);
    expect(surfaceOf(surface)).toBeUndefined();
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ATOMS} atoms in one slot`, () => {
    const surface = validSurface();
    const steps = sectionOf(surface).steps as Record<string, unknown>[];
    steps[1].extra = Array.from({ length: EXTENSION_UI_SURFACE_MAX_ATOMS + 1 }, (_, index) => ({
      type: "divider",
      id: `divider-${index}`,
    }));
    expect(problemOf(surface)).toMatch(/atoms exceeds/);
    expect(surfaceOf(surface)).toBeUndefined();
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_SPANS} text spans across the surface`, () => {
    const surface = validSurface();
    const steps = sectionOf(surface).steps as Record<string, unknown>[];
    const spans = Array.from({ length: 200 }, (_, index) => ({ text: `span ${index}` }));
    steps[1].extra = [
      { type: "text", spans },
      { type: "text", spans },
    ];
    expect(problemOf(surface)).toMatch(/text spans/);
    expect(surfaceOf(surface)).toBeUndefined();
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_COLUMNS} columns`, () => {
    const surface = validSurface();
    const section = sectionOf(surface);
    surface.sections = [
      {
        ...section,
        composite: "dataTable",
        columns: Array.from({ length: EXTENSION_UI_SURFACE_MAX_COLUMNS + 1 }, (_, index) => ({
          id: `column-${index}`,
          title: `Column ${index}`,
        })),
        rows: [],
        actions: [],
      },
    ];
    expect(surfaceOf(surface)).toBeUndefined();
    expect(problemOf(surface)).toMatch(/columns/);
  });

  it(`refuses a cell longer than ${EXTENSION_UI_SURFACE_MAX_CELL_CHARS} characters`, () => {
    const surface = tableSurface();
    const section = sectionOf(surface) as { columns: Array<{ id: string }> };
    (section.rows as Array<{ cells: Record<string, string | number | null> }>)[0].cells[
      section.columns[0].id
    ] = "x".repeat(EXTENSION_UI_SURFACE_MAX_CELL_CHARS + 1);
    expect(surfaceOf(surface)).toBeUndefined();
    expect(problemOf(surface)).toMatch(/cell exceeds/);
  });

  it(`refuses a surface larger than ${EXTENSION_UI_SURFACE_MAX_BYTES} bytes`, () => {
    const surface = validSurface();
    const section = sectionOf(surface) as { steps: Array<Record<string, unknown>> };
    section.steps = Array.from({ length: EXTENSION_UI_SURFACE_MAX_ITEMS }, (_, index) => ({
      id: `step-${index}`,
      title: "x".repeat(200),
      state: "running",
      detail: "y".repeat(200),
    }));
    const json = JSON.stringify(surface);
    expect(Buffer.byteLength(json, "utf8")).toBeGreaterThan(EXTENSION_UI_SURFACE_MAX_BYTES);
    expect(surfaceOf(surface)).toBeUndefined();
  });

  it("refuses an empty or failure state without its words", () => {
    const empty = validSurface();
    sectionOf(empty).state = { kind: "empty" };
    expect(problemOf(empty)).toMatch(/needs title and message/);

    const failure = validSurface();
    sectionOf(failure).state = { kind: "failure", title: "It broke" };
    expect(problemOf(failure)).toMatch(/needs title and message/);
  });

  it("refuses an action id that is not in the surface's action table", () => {
    const surface = validSurface();
    sectionOf(surface).actions = ["retry", "notOffered"];
    expect(problemOf(surface)).toMatch(/not in the surface's action table/);
  });

  it("refuses a composite the slice does not draw", () => {
    expect(surfaceOf(fixtures["unknown-composite.json"])).toBeUndefined();
    expect(problemOf(fixtures["unknown-composite.json"])).toMatch(/not one of/);
  });

  it("refuses a oneShot surface without a deadline", () => {
    const surface = JSON.parse(JSON.stringify(fixtures["action-bar.json"])) as Record<
      string,
      unknown
    >;
    delete surface.timeoutAt;
    expect(problemOf(surface)).toMatch(/timeoutAt/);
  });

  it("refuses a placement this slice cannot draw", () => {
    const surface = validSurface();
    surface.placement = { kind: "sheet" };
    expect(problemOf(surface)).toMatch(/not one of/);
  });

  it("refuses duplicate composite ids and duplicate row ids", () => {
    const duplicateComposite = validSurface();
    const section = sectionOf(duplicateComposite);
    duplicateComposite.sections = [section, { ...section }];
    expect(problemOf(duplicateComposite)).toMatch(/duplicate composite/);

    const duplicateRows = tableSurface();
    const rows = (sectionOf(duplicateRows) as { rows: Array<Record<string, unknown>> }).rows;
    rows[1].id = rows[0].id;
    expect(problemOf(duplicateRows)).toMatch(/duplicate row/);
  });

  it("refuses a cell or sort that names an unknown column", () => {
    const surface = tableSurface();
    (sectionOf(surface).sort as { columnId: string }).columnId = "missing";
    expect(problemOf(surface)).toMatch(/unknown column/);
  });
});

describe("extension surface patches", () => {
  it("merges dotted paths and deletes a field with null", () => {
    const surface = surfaceOf(validSurface());
    expect(surface).toBeDefined();
    const patched = applyExtensionUISurfacePatch(surface!, {
      "sections.0.phase": "queued",
      "sections.0.header.subtitle": null,
      "sections.0.steps.1.state": "queued",
      "header.title": "web → staging",
    });
    expect(patched).toBeDefined();
    expect(patched!.sections[0]).toMatchObject({ phase: "queued" });
    expect(patched!.sections[0].header.subtitle).toBeUndefined();
    expect(patched!.header.title).toBe("web → staging");
    const steps = (patched!.sections[0] as { steps?: Array<{ state: string }> }).steps;
    expect(steps?.[1].state).toBe("queued");
    // A patch never advances the revision: the server owns that.
    expect(patched!.revision).toBe(surface!.revision);
  });

  it("drops a patch whole when the merged surface would be invalid", () => {
    const surface = surfaceOf(validSurface())!;
    expect(
      applyExtensionUISurfacePatch(surface, { "sections.0.state": { kind: "empty" } }),
    ).toBeUndefined();
    expect(
      applyExtensionUISurfacePatch(surface, { "sections.0.actions": ["notOffered"] }),
    ).toBeUndefined();
    expect(applyExtensionUISurfacePatch(surface, { "sections.9.phase": "queued" })).toBeUndefined();
  });

  it("refuses identity, prototype, and non-object patches", () => {
    const surface = surfaceOf(validSurface())!;
    expect(applyExtensionUISurfacePatch(surface, { id: "other" })).toBeUndefined();
    expect(applyExtensionUISurfacePatch(surface, { version: 1 })).toBeUndefined();
    expect(applyExtensionUISurfacePatch(surface, { "__proto__.polluted": true })).toBeUndefined();
    expect(applyExtensionUISurfacePatch(surface, {})).toBeUndefined();
    expect(applyExtensionUISurfacePatch(surface, "status.phase")).toBeUndefined();
  });
});

describe("extension surface v1 projection", () => {
  it("keeps a dataTable a grid and every other composite its fallback text", () => {
    const table = surfaceOf(tableSurface())!;
    const grid = projectExtensionUISurfaceToV1(table);
    expect(grid.version).toBe(1);
    expect(grid.id).toBe("surface:query");
    expect(grid.blocks[0]).toMatchObject({
      type: "table",
      columns: ["Name", "Type", "Rows"],
      rows: [
        ["sessions", "table", 12],
        ["events", "table", 4021],
      ],
    });

    const status = surfaceOf(validSurface())!;
    const projected = projectExtensionUISurfaceToV1(status);
    const text = projected.blocks[0] as { type: string; spans: Array<{ text: string }> };
    expect(text.type).toBe("text");
    expect(text.spans[0].text).toContain("Deploying 4f2c1ab");
  });

  it("produces a surface the v1 normalizer accepts unchanged", () => {
    for (const name of [
      "status-card.json",
      "checklist.json",
      "data-table.json",
      "action-bar.json",
    ]) {
      const surface = surfaceOf(fixtures[name])!;
      const projected = projectExtensionUISurfaceToV1(surface);
      expect(normalizeExtensionUINativeSurface(projected), name).toEqual(projected);
    }
  });

  it("clips a table that is wider or longer than v1 draws", () => {
    const table = surfaceOf(tableSurface())!;
    const section = table.sections[0] as {
      columns: Array<{ id: string; title: string }>;
      rows: Array<{ id: string; cells: Record<string, string | number | null> }>;
    };
    const unsorted = { ...section } as Record<string, unknown>;
    delete unsorted.sort;
    delete unsorted.selectedRowId;
    const wide = {
      ...table,
      sections: [
        {
          ...unsorted,
          columns: Array.from({ length: EXTENSION_UI_SURFACE_MAX_COLUMNS }, (_, index) => ({
            id: `c${index}`,
            title: `C${index}`,
          })),
          rows: [
            {
              id: "row",
              cells: Object.fromEntries(
                Array.from({ length: EXTENSION_UI_SURFACE_MAX_COLUMNS }, (_, index) => [
                  `c${index}`,
                  `value ${index}`,
                ]),
              ),
            },
          ],
        },
      ],
    };
    const normalized = surfaceOf(wide)!;
    const grid = projectExtensionUISurfaceToV1(normalized);
    const block = grid.blocks[0] as { columns: string[]; truncated?: boolean };
    expect(block.columns).toHaveLength(EXTENSION_UI_SURFACE_MAX_COLUMNS);
    expect(block.truncated).toBeUndefined();
  });
});
