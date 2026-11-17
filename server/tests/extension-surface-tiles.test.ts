import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  projectExtensionUISurfaceToV1,
  readExtensionUISurface,
  EXTENSION_UI_SURFACE_MAX_NODES,
  EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN,
} from "../src/extension-surface.js";
import { withTilesAsLinks } from "../src/extension-surface-projection.js";
import { normalizeExtensionUINativeSurface } from "../src/extension-ui-contract.js";
import { decodePaneLink } from "../src/pane-link.js";
import type { ExtensionUISurface } from "../src/types.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();

interface LinkVector {
  name: string;
  input: string;
  server?: string | null;
  route?: unknown;
  error?: { code: string; detail?: string };
  notPaneLink?: boolean;
}

describe("pane link decoding", () => {
  // The same vectors Apple's PaneLinkCodecTests decodes: one rule set on both sides.
  const vectors = (
    JSON.parse(readFileSync(new URL("../../protocol/links.json", import.meta.url), "utf8")) as {
      vectors: LinkVector[];
    }
  ).vectors;

  it.each(vectors.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const decoded = decodePaneLink(vector.input);
    if (vector.notPaneLink) return expect(decoded).toBeUndefined();
    if (vector.error) return expect(decoded).toEqual({ ok: false, error: vector.error });
    expect(decoded).toEqual({ ok: true, link: { server: vector.server, route: vector.route } });
  });
});

function tilesSurface(node: Record<string, unknown>): Record<string, unknown> {
  const value = JSON.parse(JSON.stringify(fixtures["blocks-tiles.json"])) as Record<
    string,
    unknown
  >;
  (value.sections as Array<Record<string, unknown>>)[0].body = node;
  return value;
}

function problemOf(value: unknown): string | undefined {
  const read = readExtensionUISurface(value);
  return "problem" in read ? read.problem : undefined;
}

function withLink(link: string): string | undefined {
  return problemOf(tilesSurface({ type: "tiles", items: [{ id: "t", link }] }));
}

describe("tiles validation", () => {
  it("accepts the fixture and keeps every tile's fields", () => {
    const read = readExtensionUISurface(fixtures["blocks-tiles.json"]);
    if ("problem" in read) throw new Error(read.problem);
    expect(read.surface).toEqual(fixtures["blocks-tiles.json"]);
  });

  it("accepts a link to every route a pin can name", () => {
    for (const link of [
      "oppi://session/abc",
      "oppi://thread/abc",
      "oppi://sessions?workspace=ws-1",
      "oppi://file?workspace=ws-1&worktree=wt-1&path=src/a.ts#L4",
      "oppi://file?host=1&path=~/notes/a.md",
      "oppi://file?session=abc&path=out/a.png",
      "oppi://files?workspace=ws-1&path=docs",
      "oppi://files?host=1",
      "oppi://panel?session=abc&id=jobs",
      "oppi://browser?url=https%3A%2F%2Fexample.com%2F",
      "oppi://godot?project=tide-3fa9c2b1",
    ]) {
      expect(withLink(link), link).toBeUndefined();
    }
  });

  it("refuses a link that is not a pane link, or that breaks the link rules", () => {
    expect(withLink("https://example.com/")).toBe('tile "t" link is not an oppi:// pane link');
    expect(withLink("oppi://connect?v=3&invite=abc")).toBe(
      'tile "t" link is not an oppi:// pane link',
    );
    expect(withLink("oppi://file?path=a.txt")).toBe(
      'tile "t" link is invalid: missing (workspace)',
    );
    expect(withLink("oppi://godot?project=tide&level=2")).toBe(
      'tile "t" link is invalid: unknownParameter (level)',
    );
    expect(withLink("oppi://browser?url=http%3A%2F%2Flocalhost%3A5173%2F")).toBe(
      'tile "t" link is invalid: invalidValue (url)',
    );
  });

  it("refuses a link to another server, to Git, or out of its root", () => {
    expect(withLink("oppi://session/abc?server=sha256:9f86d081884c7d65")).toBe(
      'tile "t" link names a server; a tile opens on its own',
    );
    expect(withLink("oppi://git?workspace=ws-1")).toBe(
      'tile "t" link names a route a pin cannot name',
    );
    expect(withLink("oppi://file?workspace=ws-1&path=../secrets.txt")).toMatch(
      /^tile "t" link: A workspace file pin names a path inside the checkout/,
    );
    expect(withLink("oppi://file?host=1&path=/etc/passwd")).toMatch(
      /^tile "t" link: A Home file pin names a path inside ~\//,
    );
    expect(withLink("oppi://godot?project=../../tide")).toMatch(
      /^tile "t" link: A game pin names a Godot project id/,
    );
  });

  it(`holds 1 to ${EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN} tiles, each counted as a node`, () => {
    const tiles = (count: number, prefix = "t") =>
      Array.from({ length: count }, (_, index) => ({
        id: `${prefix}${index}`,
        link: `oppi://session/s${index}`,
      }));
    expect(problemOf(tilesSurface({ type: "tiles", items: [] }))).toBe("a tiles node has no tiles");
    expect(
      problemOf(
        tilesSurface({ type: "tiles", items: tiles(EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN + 1) }),
      ),
    ).toBe(`tiles exceeds ${EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN} entries`);
    // 24 groups of 12 tiles and a group node each: 24 * 13 = 312 nodes, past the cap of 300.
    const groups = Array.from({ length: 24 }, (_, group) => ({
      type: "tiles",
      items: tiles(EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN, `g${group}-`),
    }));
    const nested = {
      type: "stack",
      children: Array.from({ length: 2 }, (_, half) => ({
        type: "stack",
        children: groups.slice(half * 12, half * 12 + 12),
      })),
    };
    expect(problemOf(tilesSurface(nested))).toBe(
      `the surface exceeds ${EXTENSION_UI_SURFACE_MAX_NODES} nodes`,
    );
  });

  it("needs a stable id on every tile, unique across the surface", () => {
    const tile = { id: "files", link: "oppi://session/abc" };
    expect(problemOf(tilesSurface({ type: "tiles", items: [{ link: tile.link }] }))).toBe(
      "an id is not a stable identifier",
    );
    // The node's own id and a tile's share the surface's one namespace.
    expect(problemOf(tilesSurface({ type: "tiles", id: "files", items: [tile] }))).toBe(
      'duplicate node id "files"',
    );
    expect(problemOf(tilesSurface({ type: "tiles", items: [tile, tile] }))).toBe(
      'duplicate node id "files"',
    );
  });

  it("caps a tile's words, and refuses an empty title, a tone, or an action", () => {
    const tile = { id: "t", link: "oppi://session/abc" };
    expect(
      problemOf(tilesSurface({ type: "tiles", items: [{ ...tile, title: "x".repeat(201) }] })),
    ).toBe("a string field exceeds 200 characters");
    expect(problemOf(tilesSurface({ type: "tiles", items: [{ ...tile, subtitle: " " }] }))).toBe(
      "a string field is empty",
    );
    expect(problemOf(tilesSurface({ type: "tiles", tone: "accent", items: [tile] }))).toBe(
      'a "tiles" node does not take a tone',
    );
    expect(problemOf(tilesSurface({ type: "tiles", action: { id: "retry" }, items: [tile] }))).toBe(
      'a "tiles" node cannot offer an action',
    );
  });

  it("keeps tiles out of the pill", () => {
    const value = tilesSurface({ type: "tiles", items: [{ id: "t", link: "oppi://session/a" }] });
    value.pill = {
      content: {
        type: "row",
        children: [{ type: "tiles", items: [{ id: "p", link: "oppi://session/b" }] }],
      },
      tap: "drawer",
    };
    expect(problemOf(value)).toBe('a pill cannot hold a "tiles" node');
  });

  it("projects each tile to a v1 line of text that opens its link", () => {
    const read = readExtensionUISurface(fixtures["blocks-tiles.json"]);
    if ("problem" in read) throw new Error(read.problem);
    const projection = projectExtensionUISurfaceToV1(read.surface as ExtensionUISurface);
    expect(normalizeExtensionUINativeSurface(projection)).toEqual(projection);
    const lines = JSON.stringify(projection.blocks);
    // A tile without a title shows its target's own name.
    expect(lines).toContain(
      '{"type":"text","id":"file:report","spans":[{"text":"report.pdf","link":"oppi://file?session=test-session-1&path=out/report.pdf"}]}',
    );
    expect(lines).toContain(
      '{"type":"text","id":"file:notes","spans":[{"text":"Notes","link":"oppi://file?workspace=ws-1&path=docs/notes.md#L3"},{"text":" · Changed 2 times","role":"muted"}]}',
    );
  });

  it("keeps each tile one Markdown list item for a client without tiles", () => {
    const read = readExtensionUISurface(
      tilesSurface({
        type: "tiles",
        id: "places",
        items: [
          {
            id: "page",
            link: "oppi://browser?url=https://example.com/a>b\nc",
            title: "Two\nlines [and] *stars*",
            subtitle: "next\r\n- [x](oppi://session/evil)",
          },
        ],
      }),
    );
    if ("problem" in read) throw new Error(read.problem);
    const section = withTilesAsLinks(read.surface).sections[0] as { body: { markdown: string } };
    expect(section.body.markdown).toBe(
      "- [Two lines \\[and\\] \\*stars\\*](<oppi://browser?url=https://example.com/a%3Eb%0Ac>)" +
        " · next - \\[x\\](oppi://session/evil)",
    );
  });
});
