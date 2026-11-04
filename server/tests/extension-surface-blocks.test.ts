import { describe, expect, it } from "vitest";

import {
  applyExtensionUISurfacePatch,
  projectExtensionUISurfaceToV1,
  readExtensionUISurface,
  EXTENSION_UI_SURFACE_MAX_ACTIONS,
  EXTENSION_UI_SURFACE_MAX_CELL_CHARS,
  EXTENSION_UI_SURFACE_MAX_NODE_DEPTH,
  EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS,
  EXTENSION_UI_SURFACE_MAX_NODES,
  EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN,
} from "../src/extension-surface.js";
import { normalizeExtensionUINativeSurface } from "../src/extension-ui-contract.js";
import type { ExtensionUISurface } from "../src/types.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();

function surfaceOf(value: unknown): ExtensionUISurface | undefined {
  const read = readExtensionUISurface(value);
  return "problem" in read ? undefined : read.surface;
}

function problemOf(value: unknown): string | undefined {
  const read = readExtensionUISurface(value);
  return "problem" in read ? read.problem : undefined;
}

function panel(): Record<string, unknown> {
  return JSON.parse(JSON.stringify(fixtures["blocks-panel.json"])) as Record<string, unknown>;
}

/** A surface whose one tree section carries `node` as its body. */
function withBody(node: Record<string, unknown>): Record<string, unknown> {
  const value = panel();
  (value.sections as Array<Record<string, unknown>>)[0].body = node;
  return value;
}

function children(count: number): Array<Record<string, unknown>> {
  return Array.from({ length: count }, (_, index) => ({
    type: "text",
    id: `n${index}`,
    text: `line ${index}`,
  }));
}

describe("blocks validation", () => {
  it("accepts the fixtures that use every node kind and both pill taps", () => {
    for (const name of ["blocks-panel.json", "blocks-status.json"]) {
      const surface = surfaceOf(fixtures[name]);
      expect(surface, name).toBeDefined();
      expect(surface?.version).toBe(2);
    }
  });

  it("defaults a tree section's state and leaves its header optional", () => {
    const value = panel();
    const section = (value.sections as Array<Record<string, unknown>>)[0];
    delete section.state;
    delete section.header;
    const surface = surfaceOf(value);
    expect(surface).toBeDefined();
    const blocks = surface?.sections[0];
    expect(blocks?.composite).toBe("blocks");
    if (blocks?.composite !== "blocks") throw new Error("expected a blocks section");
    expect(blocks.state).toEqual({ kind: "content" });
    expect(blocks.header).toBeUndefined();
  });

  it(`refuses a body deeper than ${EXTENSION_UI_SURFACE_MAX_NODE_DEPTH} nodes`, () => {
    /** `stacks` nested stacks around one text: the text sits at depth `stacks + 1`. */
    const nested = (stacks: number): Record<string, unknown> => {
      let node: Record<string, unknown> = { type: "text", text: "deep" };
      for (let depth = 0; depth < stacks; depth += 1) node = { type: "stack", children: [node] };
      return node;
    };
    expect(surfaceOf(withBody(nested(EXTENSION_UI_SURFACE_MAX_NODE_DEPTH - 1)))).toBeDefined();
    expect(problemOf(withBody(nested(EXTENSION_UI_SURFACE_MAX_NODE_DEPTH)))).toContain("deeper");
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_NODES} nodes in one surface`, () => {
    /** Two levels of full fan-out: one root, 12 rows, 12 stacks, and 144 leaves. */
    const dense = (prefix: string): Record<string, unknown> => ({
      type: "stack",
      children: Array.from({ length: EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN }, (_, row) => ({
        type: "row",
        id: `${prefix}row${row}`,
        children: [
          {
            type: "stack",
            id: `${prefix}stack${row}`,
            children: Array.from({ length: EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN }, (_, leaf) => ({
              type: "text",
              id: `${prefix}leaf${row}-${leaf}`,
              text: "line",
            })),
          },
        ],
      })),
    });
    const value = panel();
    const section = (value.sections as Array<Record<string, unknown>>)[0];
    section.body = dense("a");
    expect(surfaceOf(value)).toBeDefined();
    (value.sections as Array<Record<string, unknown>>).push({ ...section, id: "second", body: dense("b") });
    expect(problemOf(value)).toContain("nodes");
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN} children in a row`, () => {
    const wide = withBody({
      type: "row",
      children: children(EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN + 1),
    });
    expect(problemOf(wide)).toContain("12");
  });

  it("refuses a layout node with no children and a duplicate node id", () => {
    expect(problemOf(withBody({ type: "row", children: [] }))).toContain("no children");
    expect(
      problemOf(
        withBody({
          type: "stack",
          children: [
            { type: "text", id: "same", text: "one" },
            { type: "text", id: "same", text: "two" },
          ],
        }),
      ),
    ).toContain("duplicate node id");
  });

  it("refuses an icon name outside the host's allow-list", () => {
    expect(problemOf(withBody({ type: "icon", name: "not.a.symbol" }))).toContain(
      "not an allowed icon name",
    );
    expect(surfaceOf(withBody({ type: "icon", name: "hammer" }))).toBeDefined();
  });

  it("refuses a node action the surface does not declare", () => {
    expect(
      problemOf(
        withBody({
          type: "button",
          id: "ghost",
          title: "Ghost",
          action: { id: "ghost-action" },
        }),
      ),
    ).toContain("not in the surface's action table");
  });

  it("refuses a control with no id and a table row with actions but no row id", () => {
    expect(
      problemOf(withBody({ type: "button", title: "Retry", action: { id: "retry" } })),
    ).toContain("interactive node has no id");
    expect(
      problemOf(
        withBody({
          type: "table",
          id: "gates",
          columns: ["Gate"],
          rows: [{ cells: ["Build"], actions: [{ id: "copyRow" }] }],
        }),
      ),
    ).toContain("row with actions has no id");
    expect(
      problemOf(
        withBody({
          type: "table",
          columns: ["Gate"],
          rows: [{ id: "build", cells: ["Build"], actions: [{ id: "copyRow" }] }],
        }),
      ),
    ).toContain("table with row actions has no id");
  });

  it("drops a style field a node does not have, and refuses values the round trip cannot carry", () => {
    // The schema is the palette: a field it does not name is not a style the host would honour.
    const styled = surfaceOf(withBody({ type: "text", text: "hi", color: "red" }));
    expect(styled).toBeDefined();
    const body = (styled as ExtensionUISurface).sections[0];
    if (body.composite !== "blocks") throw new Error("expected a blocks section");
    expect(JSON.stringify(body.body)).not.toContain("red");
    expect(
      problemOf(
        withBody({
          type: "button",
          id: "retry",
          title: "Retry",
          action: { id: "retry", values: { nested: { a: 1 } } },
        }),
      ),
    ).toContain("not a string, number, or boolean");
  });

  it(`caps node strings at ${EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS} and table cells at ${EXTENSION_UI_SURFACE_MAX_CELL_CHARS}`, () => {
    expect(
      surfaceOf(withBody({ type: "text", text: "x".repeat(EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) })),
    ).toBeDefined();
    expect(
      problemOf(withBody({ type: "text", text: "x".repeat(EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS + 1) })),
    ).toContain("characters");
    expect(
      problemOf(
        withBody({
          type: "table",
          id: "gates",
          columns: ["Gate"],
          rows: [{ id: "build", cells: ["x".repeat(EXTENSION_UI_SURFACE_MAX_CELL_CHARS + 1)] }],
        }),
      ),
    ).toContain("characters");
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ACTIONS} actions in the action table`, () => {
    const value = panel();
    value.actions = Object.fromEntries(
      Array.from({ length: EXTENSION_UI_SURFACE_MAX_ACTIONS + 1 }, (_, index) => [
        `action${index}`,
        { title: `Action ${index}` },
      ]),
    );
    expect(problemOf(value)).toContain("action table");
  });

  it("refuses a pill that is not a row of inline facts, or that holds its own tap", () => {
    const notARow = panel();
    notARow.pill = {
      content: { type: "text", text: "one" },
      tap: "drawer",
    };
    expect(problemOf(notARow)).toContain("row of inline nodes");

    const control = panel();
    control.pill = {
      content: {
        type: "row",
        children: [{ type: "button", id: "extra", title: "Retry", action: { id: "retry" } }],
      },
      tap: "drawer",
    };
    expect(problemOf(control)).toContain("cannot hold");

    const ownTap = panel();
    ownTap.pill = {
      content: {
        type: "row",
        children: [{ type: "text", text: "deploy", action: { id: "refresh" } }],
      },
      tap: "drawer",
    };
    expect(problemOf(ownTap)).toContain("its own action");
  });

  it("reserves the pill's name as a section id", () => {
    const value = panel();
    (value.sections as Array<Record<string, unknown>>)[0].id = "pill";
    expect(problemOf(value)).toContain("reserved");
  });

  it("refuses a pill action the surface does not declare", () => {
    const value = panel();
    value.pill = {
      content: { type: "row", children: [{ type: "badge", text: "running" }] },
      tap: { action: { id: "ghost" } },
    };
    expect(problemOf(value)).toContain("not in the surface's action table");
  });
});

describe("blocks patches", () => {
  it("merges into a body by child index and by node id", () => {
    const surface = surfaceOf(panel());
    expect(surface).toBeDefined();
    const patch = (fixtures["blocks-patch.json"] as Record<string, unknown>).patch as Record<
      string,
      unknown
    >;
    const merged = applyExtensionUISurfacePatch(surface as ExtensionUISurface, patch);
    expect(merged).toBeDefined();
    const section = merged?.sections[0];
    if (section?.composite !== "blocks") throw new Error("expected a blocks section");
    const root = section.body;
    if (root.type !== "stack") throw new Error("expected a stack body");
    expect(root.children[1]).toMatchObject({ type: "progress", value: 0.7 });
    const headline = root.children[0];
    if (headline.type !== "row") throw new Error("expected a row");
    expect(headline.children[1]).toMatchObject({ type: "badge", id: "state", text: "3 of 4" });
    const table = root.children.find((child) => child.id === "gates");
    if (table?.type !== "table") throw new Error("expected the table node");
    expect(table.rows[0].cells).toEqual(["Build", "running"]);
  });

  it("refuses a body path that names no node, and one that crosses a value", () => {
    const surface = surfaceOf(panel()) as ExtensionUISurface;
    expect(
      applyExtensionUISurfacePatch(surface, { "sections.0.body.children.#ghost.text": "x" }),
    ).toBeUndefined();
    expect(
      applyExtensionUISurfacePatch(surface, { "sections.0.body.children.0.children.0.text.more": 1 }),
    ).toBeUndefined();
  });

  it("drops a body patch whose merge the schema would refuse", () => {
    const surface = surfaceOf(panel()) as ExtensionUISurface;
    expect(
      applyExtensionUISurfacePatch(surface, { "sections.0.body.children.#icon.name": "nope" }),
    ).toBeUndefined();
  });
});

describe("blocks v1 projection", () => {
  type V1Block = { type: string; blocks?: V1Block[]; spans?: Array<{ text: string }> };

  function projected(): ReturnType<typeof projectExtensionUISurfaceToV1> {
    const surface = surfaceOf(panel());
    if (!surface) throw new Error("the panel fixture must validate");
    return projectExtensionUISurfaceToV1(surface);
  }

  /** Every block, at any depth: a row's children land inside the section that groups them. */
  function flatten(blocks: readonly unknown[]): V1Block[] {
    const flat: V1Block[] = [];
    for (const entry of blocks as V1Block[]) {
      flat.push(entry);
      if (entry.blocks) flat.push(...flatten(entry.blocks));
    }
    return flat;
  }

  it("maps every node kind to a v1 block a client can draw", () => {
    const blocks = flatten(projected().blocks);
    const types = blocks.map((block) => block.type);
    for (const type of [
      "text",
      "markdown",
      "progress",
      "table",
      "chart",
      "code",
      "divider",
      "spacer",
      "section",
    ]) {
      expect(types, type).toContain(type);
    }
    expect(blocks.find((block) => block.type === "table")).toMatchObject({
      columns: ["Gate", "State"],
    });
    // A key/value node is one text block with its pairs on their own lines.
    const pairs = blocks.find((block) => block.spans?.[0].text.includes("Env: prod"));
    expect(pairs?.spans?.[0].text).toContain("Commit: 4f2c1ab");
  });

  it("reads a row of inline facts as one line and keeps a taller one a group", () => {
    const blocks = flatten(projected().blocks);
    const line = blocks.find((block) => block.spans?.[0].text.includes("Deploying 4f2c1ab"));
    expect(line?.spans?.[0].text).toContain("2 of 4");
    // The controls live in their own stack, which v1 draws as a group, not one run-on line.
    expect(blocks.some((block) => block.type === "section")).toBe(true);
  });

  it("names the controls it cannot draw instead of losing their verbs", () => {
    const surface = projected();
    const text = surface.blocks
      .map((block) => JSON.stringify(block))
      .filter((block) => block.includes("Actions: "))
      .join("");
    expect(text).toContain("Retry");
    expect(text).toContain("Notify on failure (off)");
    expect(text).toContain("Logs");
  });

  it("keeps a composed pill as the panel's own line", () => {
    const surface = projected();
    const subtitle = (surface.presentation as { subtitle?: string }).subtitle;
    expect(subtitle).toBe("web → prod · running");
  });

  it("projects a region that is not showing its content as its words", () => {
    const failing = panel();
    (failing.sections as Array<Record<string, unknown>>)[0].state = {
      kind: "failure",
      title: "Deploy failed",
      message: "The test gate timed out.",
    };
    const surface = projectExtensionUISurfaceToV1(surfaceOf(failing) as ExtensionUISurface);
    expect(surface.blocks).toHaveLength(1);
    expect(JSON.stringify(surface.blocks[0])).toContain("2 of 4 gates");
  });

  it("produces a surface the v1 normalizer accepts unchanged", () => {
    for (const name of ["blocks-panel.json", "blocks-status.json"]) {
      const surface = surfaceOf(fixtures[name]);
      expect(surface, name).toBeDefined();
      const projection = projectExtensionUISurfaceToV1(surface as ExtensionUISurface);
      expect(normalizeExtensionUINativeSurface(projection), name).toEqual(projection);
    }
  });
});
