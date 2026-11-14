import { afterEach, describe, expect, it, vi } from "vitest";

import {
  EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
  EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
  EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
  EXTENSION_NATIVE_UI_PANEL_CAPABILITY,
  EXTENSION_NATIVE_UI_WORKING_CAPABILITY,
} from "../src/extension-ui-contract.js";
import { readExtensionUISurface } from "../src/extension-surface.js";
import type { ExtensionUISurfaceAudience } from "../src/extension-surface-runtime.js";
import { SessionSurfaces } from "../src/session-surfaces.js";
import type {
  ExtensionUISurface,
  ExtensionUISurfaceActionMessage,
  ServerMessage,
} from "../src/types.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const SESSION = "session-surfaces-1";
const fixtures = buildSurfaceFixtures();

function surfaceOf(overrides: Record<string, unknown> = {}): ExtensionUISurface {
  const read = readExtensionUISurface({
    ...JSON.parse(JSON.stringify(fixtures["status-card.json"])),
    ...overrides,
  });
  if ("problem" in read) throw new Error(read.problem);
  return read.surface;
}

function tap(
  overrides: Partial<ExtensionUISurfaceActionMessage> = {},
): ExtensionUISurfaceActionMessage {
  return {
    surfaceId: "deploy",
    compositeId: "status",
    actionId: "retry",
    revision: 1,
    ...overrides,
  };
}

/** One frame, with the shape it was built for. */
interface Frame {
  message: ServerMessage;
  audience: ExtensionUISurfaceAudience;
}

function harness() {
  const frames: Frame[] = [];
  const surfaces = new SessionSurfaces({
    sessionId: SESSION,
    emit: (message, audience) => frames.push({ message, audience }),
  });
  const of = <T extends ServerMessage["type"]>(type: T, audience?: ExtensionUISurfaceAudience) =>
    frames
      .filter((frame) => frame.message.type === type)
      .filter((frame) => audience === undefined || frame.audience === audience)
      .map((frame) => frame.message as Extract<ServerMessage, { type: T }>);
  return { surfaces, frames, of };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("SessionSurfaces", () => {
  it("publishes a surface to the clients that draw composites, and its v1 projection to the rest", () => {
    const h = harness();
    h.surfaces.publisher.publish(surfaceOf(), undefined);

    const surfaces = h.of("extension_ui_surface", "composites");
    expect(surfaces).toHaveLength(1);
    expect(surfaces[0]?.surface.id).toBe("deploy");
    expect(surfaces[0]?.sessionId).toBe(SESSION);

    const projections = h.of("extension_ui_notification", "v1-projection");
    expect(projections).toHaveLength(1);
    expect(projections[0]?.widgetKey).toBe("surface:deploy");
    expect(projections[0]?.nativeSurface?.version).toBe(1);
  });

  it("hands a late client the live surfaces in the shape it draws", () => {
    const h = harness();
    h.surfaces.publisher.publish(surfaceOf(), undefined);

    const forV1 = h.surfaces.messages("old-phone");
    expect(forV1.map((message) => message.type)).toEqual(["extension_ui_notification"]);

    const upgrades = h.surfaces.declare("new-phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);
    expect(upgrades.map((message) => message.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
      "extension_ui_live_surfaces",
    ]);
    // The widget the client was handed at subscribe is cleared in the same breath.
    expect(upgrades[0]).toMatchObject({ widgetKey: "surface:deploy", widgetLines: [] });
    expect(h.surfaces.audience("new-phone")).toBe("composites");
    // A repeat declaration changes nothing and sends nothing.
    expect(h.surfaces.declare("new-phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY])).toEqual(
      [],
    );
    expect(h.surfaces.declare("old-phone", [])).toEqual([]);
  });

  it("runs the panel's handler for a client that drew the card, and patches it", async () => {
    const h = harness();
    const seen: Array<Record<string, unknown>> = [];
    h.surfaces.publisher.publish(surfaceOf(), async (request) => {
      seen.push(request);
      return { patch: { "sections.0.phase": "success" } };
    });
    h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);

    await expect(
      h.surfaces.act(tap({ requestId: "tap-1", values: { env: "prod" }, revision: 1 }), "phone"),
    ).resolves.toBe(true);

    expect(seen).toEqual([
      {
        compositeId: "status",
        actionId: "retry",
        revision: 1,
        values: { env: "prod" },
        signal: expect.any(AbortSignal),
      },
    ]);
    const patches = h.of("extension_ui_patch", "composites");
    expect(patches).toHaveLength(1);
    expect(patches[0]).toMatchObject({
      surfaceId: "deploy",
      revision: 2,
      patch: { "sections.0.phase": "success" },
    });
    // Every round trip ends: the tap's own request id comes back settled.
    expect(h.of("extension_ui_settled", "composites").map((message) => message.id)).toEqual([
      "tap-1",
    ]);
    // The v1 client is told the same change as a fresh projection of the card.
    expect(h.of("extension_ui_notification", "v1-projection").length).toBeGreaterThan(1);
  });

  it("refuses a tap from a client that only ever saw the v1 projection", async () => {
    const h = harness();
    let ran = 0;
    h.surfaces.publisher.publish(surfaceOf(), async () => {
      ran += 1;
      return { patch: {} };
    });
    await expect(h.surfaces.act(tap({ requestId: "tap-2" }), "old-phone")).resolves.toBe(true);
    expect(ran).toBe(0);
    expect(h.of("extension_ui_settled", "v1-projection").map((message) => message.id)).toEqual([
      "tap-2",
    ]);
  });

  it("answers a tap that reaches no handler without running anything", async () => {
    const h = harness();
    // A wire surface published with no dispatch (a host-side publish, not a panel's).
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);
    await expect(h.surfaces.act(tap({ requestId: "tap-3" }), "phone")).resolves.toBe(true);
    expect(h.of("extension_ui_patch", "composites").at(-1)?.patch).toEqual({
      "sections.0.state": {
        kind: "failure",
        title: "Action failed",
        message: "This surface's action is no longer running.",
      },
    });
  });

  it("tells a client that taps a surface the session never published here to clear it", async () => {
    // A phone still draws a card from before the server restarted: this Session has no surface
    // loop yet, and the tap is answered by clearing the card rather than with nothing.
    const h = harness();
    h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);
    expect(h.surfaces.canAct()).toBe(true);
    await expect(h.surfaces.act(tap({ revision: 5, requestId: "tap-4" }), "phone")).resolves.toBe(
      true,
    );
    expect(h.of("extension_ui_patch", "composites")).toEqual([
      expect.objectContaining({ surfaceId: "deploy", revision: 6, removed: true }),
    ]);
    expect(h.of("extension_ui_settled", "composites").map((message) => message.id)).toEqual([
      "tap-4",
    ]);
    // A publish of the same id afterwards continues above the removal the phone was sent.
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(h.of("extension_ui_surface", "composites").at(-1)?.surface.revision).toBe(7);
  });

  it("acts on nothing once the session has stopped", async () => {
    const h = harness();
    h.surfaces.publisher.publish(surfaceOf(), async () => ({ patch: {} }));
    expect(h.surfaces.canAct()).toBe(true);
    h.surfaces.stop();
    expect(h.surfaces.canAct()).toBe(false);
    await expect(h.surfaces.act(tap(), "phone")).resolves.toBe(false);
  });

  it("tells a v2 client which surfaces it holds, so one removed while it was away clears", () => {
    const h = harness();
    // Nothing published yet: a v2 client is still told it holds nothing.
    expect(h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY])).toEqual([
      { type: "extension_ui_live_surfaces", surfaceIds: [], sessionId: SESSION },
    ]);
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    h.surfaces.publisher.publish(surfaceOf({ id: "release" }), undefined);
    // The phone goes away, and the panel ends while it is gone: the removal reaches nobody.
    h.surfaces.forget("phone");
    h.surfaces.publisher.dismiss("release");

    // It subscribes again: it is handed the surface still live, then the set it now holds.
    h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);
    const replay = h.surfaces.messages("phone");
    expect(replay.map((message) => message.type)).toEqual([
      "extension_ui_surface",
      "extension_ui_live_surfaces",
    ]);
    expect(replay.at(-1)).toEqual({
      type: "extension_ui_live_surfaces",
      surfaceIds: ["deploy"],
      sessionId: SESSION,
    });
    // A client that draws v1 widgets holds no v2 surfaces, so it is not told the set.
    expect(h.surfaces.messages("old-phone").map((message) => message.type)).toEqual([
      "extension_ui_notification",
    ]);
  });

  it("hands a tree only to a client that draws primitives", () => {
    const h = harness();
    const panel = readExtensionUISurface(fixtures["blocks-panel.json"]);
    if ("problem" in panel) throw new Error(panel.problem);
    h.surfaces.publisher.publish(panel.surface, undefined);

    // The tree goes to the blocks audience alone; a composites-only client is handed the
    // projection, because one frame cannot mix the two shapes.
    expect(h.of("extension_ui_surface", "blocks")).toHaveLength(1);
    expect(h.of("extension_ui_surface", "composites")).toHaveLength(0);
    expect(h.of("extension_ui_notification", "composites")[0]?.widgetKey).toBe(
      "surface:blocks-panel",
    );

    const forBlocks = h.surfaces.declare("new-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
    ]);
    expect(forBlocks.map((message) => message.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
      "extension_ui_live_surfaces",
    ]);
    expect(h.surfaces.audience("new-phone")).toBe("blocks");

    const forComposites = h.surfaces.declare("old-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
    ]);
    // A tree is handed to this client as a projection, so nothing is cleared first: the widget it
    // already holds is the projection it is about to be handed again.
    expect(forComposites.map((message) => message.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_live_surfaces",
    ]);
    // It holds the tree only as a widget, so the set of v2 surfaces it holds is empty.
    expect(forComposites.at(-1)).toMatchObject({ surfaceIds: [] });
    expect(h.surfaces.audience("old-phone")).toBe("composites");
    // A client that only draws composites still gets a surface that has no tree.
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(h.surfaces.messages("old-phone").map((message) => message.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
      "extension_ui_live_surfaces",
    ]);
  });

  it("rewrites an elapsed node only for a connected client that predates it", async () => {
    const h = harness();
    const value = JSON.parse(JSON.stringify(fixtures["blocks-elapsed.json"]));
    const since = Date.now() - 3_725_000;
    value.pill.content.children[2].since = since;
    value.sections[0].body.children[1].since = since;
    value.sections[0].actions = ["refresh"];
    const read = readExtensionUISurface(value);
    if ("problem" in read) throw new Error(read.problem);
    h.surfaces.declare("new-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
    ]);
    expect(h.surfaces.audience("new-phone")).toBe("elapsed");
    h.surfaces.publisher.publish(read.surface, async () => ({
      patch: { "sections.0.body.children.1.since": since + 3_600_000 },
    }));

    // Nobody draws trees without elapsed, so no static copy is built.
    expect(h.of("extension_ui_surface", "elapsed")).toHaveLength(1);
    expect(h.of("extension_ui_surface", "blocks")).toEqual([]);

    // A build that predates the node joins: it is handed the surface with the span as text.
    const joined = h.surfaces.declare("old-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
    ]);
    const handed = joined.find((message) => message.type === "extension_ui_surface");
    expect(handed?.surface.pill?.content.children[2]).toMatchObject({
      type: "text",
      text: "1:02:05",
    });

    // A patch into the node cannot land on text: that client is sent the whole surface again,
    // while the client that ticks the node gets the patch.
    await h.surfaces.act(
      tap({ surfaceId: "blocks-elapsed", compositeId: "jobs", actionId: "refresh" }),
      "new-phone",
    );
    expect(h.of("extension_ui_patch", "elapsed")).toHaveLength(1);
    expect(h.of("extension_ui_patch", "blocks")).toEqual([]);
    const resent = h.of("extension_ui_surface", "blocks").at(-1);
    expect(resent?.surface.revision).toBe(2);
    const section = resent?.surface.sections[0];
    if (section?.composite !== "blocks") throw new Error("expected a blocks section");
    expect(section.body.children[1]).toMatchObject({ type: "text", text: "2m" });
  });

  it("sends a pill's headline as caption only to a client that would draw it too large", async () => {
    const h = harness();
    const value = JSON.parse(JSON.stringify(fixtures["blocks-panel.json"]));
    value.pill.content.children[1].style = "headline";
    const read = readExtensionUISurface(value);
    if ("problem" in read) throw new Error(read.problem);
    h.surfaces.declare("new-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
    ]);
    h.surfaces.declare("old-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
    ]);
    // The answer writes a headline into the pill: a client that holds the caption copy must not
    // apply that patch as it is.
    h.surfaces.publisher.publish(read.surface, async () => ({
      patch: {
        "pill.content.children.1": { type: "text", text: "web → staging", style: "headline" },
      },
    }));

    const pillText = (surface: ExtensionUISurface | undefined) =>
      surface?.pill?.content.children[1];
    const forNew = h.of("extension_ui_surface", "elapsed")[0]?.surface;
    const forOld = h.of("extension_ui_surface", "blocks")[0]?.surface;
    expect(pillText(forNew)).toMatchObject({ text: "web → prod", style: "headline" });
    expect(pillText(forOld)).toMatchObject({ text: "web → prod", style: "caption" });
    // Only the pill's words change: the old client draws the same drawer.
    expect(forOld?.sections).toEqual(forNew?.sections);
    // A client that joins later is handed the caption copy too.
    const handed = h.surfaces
      .messages("old-phone")
      .find((message) => message.type === "extension_ui_surface");
    expect(pillText(handed?.surface)).toMatchObject({ style: "caption" });

    await h.surfaces.act(
      tap({ surfaceId: "blocks-panel", compositeId: "panel", actionId: "refresh", revision: 7 }),
      "new-phone",
    );
    expect(h.of("extension_ui_patch", "elapsed")).toHaveLength(1);
    expect(h.of("extension_ui_patch", "blocks")).toEqual([]);
    const resent = h.of("extension_ui_surface", "blocks").at(-1);
    expect(resent?.surface.revision).toBe(forOld!.revision + 1);
    expect(pillText(resent?.surface)).toMatchObject({ text: "web → staging", style: "caption" });
  });

  it("sends pane hints and a panel placement only to a client that opens panes", async () => {
    const h = harness();
    const read = readExtensionUISurface(JSON.parse(JSON.stringify(fixtures["panel-hints.json"])));
    if ("problem" in read) throw new Error(read.problem);
    const current = [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
    ];
    h.surfaces.declare("pane-phone", [...current, EXTENSION_NATIVE_UI_PANEL_CAPABILITY]);
    h.surfaces.declare("older-phone", current);
    expect(h.surfaces.audience("pane-phone")).toBe("panel");
    expect(h.surfaces.audience("older-phone")).toBe("elapsed");
    // The answer moves the surface back to the strip and widens it: a patch the older client's
    // copy, which never had the hints, cannot take as it is.
    h.surfaces.publisher.publish(read.surface, async () => ({
      patch: { "panel.size": "regular", "header.subtitle": "2 finished" },
    }));

    const forPane = h.of("extension_ui_surface", "panel")[0]?.surface;
    const forOlder = h.of("extension_ui_surface", "elapsed")[0]?.surface;
    expect(forPane?.placement.kind).toBe("panel");
    expect(forPane?.panel).toEqual({ icon: "terminal", size: "wide" });
    // An older build draws only strip surfaces: it gets this one as a strip, without the hints.
    expect(forOlder?.placement).toEqual({ kind: "strip", preferred: "aboveComposer" });
    expect(forOlder?.panel).toBeUndefined();
    expect(forOlder?.sections).toEqual(forPane?.sections);
    const handed = h.surfaces
      .messages("older-phone")
      .find((message) => message.type === "extension_ui_surface");
    expect(handed?.surface.placement.kind).toBe("strip");

    await h.surfaces.act(
      tap({ surfaceId: "jobs", compositeId: "list", actionId: "refresh", revision: 7 }),
      "pane-phone",
    );
    expect(h.of("extension_ui_patch", "panel")).toHaveLength(1);
    expect(h.of("extension_ui_patch", "elapsed")).toEqual([]);
    const resent = h.of("extension_ui_surface", "elapsed").at(-1);
    expect(resent?.surface.header.subtitle).toBe("2 finished");
    expect(resent?.surface.panel).toBeUndefined();
  });

  it("resends the whole surface to a client whose copy was rewritten, even when a patch drops the hints", async () => {
    const h = harness();
    const read = readExtensionUISurface(JSON.parse(JSON.stringify(fixtures["panel-hints.json"])));
    if ("problem" in read) throw new Error(read.problem);
    const current = [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
    ];
    h.surfaces.declare("pane-phone", [...current, EXTENSION_NATIVE_UI_PANEL_CAPABILITY]);
    h.surfaces.declare("older-phone", current);
    // After this answer the surface needs no rewrite, but the older client still holds the copy
    // that was rewritten before it, which the patch was not written against.
    h.surfaces.publisher.publish(read.surface, async () => ({
      patch: { placement: { kind: "strip", preferred: "aboveComposer" }, panel: null },
    }));

    await h.surfaces.act(
      tap({ surfaceId: "jobs", compositeId: "list", actionId: "refresh", revision: 1 }),
      "pane-phone",
    );
    expect(h.of("extension_ui_patch", "panel")).toHaveLength(1);
    expect(h.of("extension_ui_patch", "elapsed")).toEqual([]);
    expect(h.of("extension_ui_surface", "elapsed").at(-1)?.surface.revision).toBe(2);
  });

  it("resends the whole surface to a client whose copy a patch would rewrite", async () => {
    const h = harness();
    const value = JSON.parse(JSON.stringify(fixtures["panel-hints.json"]));
    value.placement = { kind: "strip", preferred: "aboveComposer" };
    delete value.panel;
    const read = readExtensionUISurface(value);
    if ("problem" in read) throw new Error(read.problem);
    const current = [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
    ];
    h.surfaces.declare("pane-phone", [...current, EXTENSION_NATIVE_UI_PANEL_CAPABILITY]);
    h.surfaces.declare("older-phone", current);
    // The answer moves a strip surface into a pane, hints the older client cannot be sent.
    h.surfaces.publisher.publish(read.surface, async () => ({
      patch: {
        placement: { kind: "panel", preferred: "aboveComposer" },
        panel: { icon: "terminal", size: "wide" },
      },
    }));

    await h.surfaces.act(
      tap({ surfaceId: "jobs", compositeId: "list", actionId: "refresh", revision: 1 }),
      "pane-phone",
    );
    expect(h.of("extension_ui_patch", "panel")).toHaveLength(1);
    expect(h.of("extension_ui_patch", "elapsed")).toEqual([]);
    const resent = h.of("extension_ui_surface", "elapsed").at(-1)?.surface;
    expect(resent?.revision).toBe(2);
    expect(resent?.placement.kind).toBe("strip");
    expect(resent?.panel).toBeUndefined();
  });

  it("sends the working mark only to a client that draws it, and a symbol to the rest", async () => {
    const h = harness();
    const read = readExtensionUISurface(
      JSON.parse(JSON.stringify(fixtures["blocks-working.json"])),
    );
    if ("problem" in read) throw new Error(read.problem);
    const pane = [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
      EXTENSION_NATIVE_UI_PANEL_CAPABILITY,
    ];
    h.surfaces.declare("new-phone", [...pane, EXTENSION_NATIVE_UI_WORKING_CAPABILITY]);
    h.surfaces.declare("pane-phone", pane);
    expect(h.surfaces.audience("new-phone")).toBe("working");
    expect(h.surfaces.audience("pane-phone")).toBe("panel");
    h.surfaces.publisher.publish(read.surface, undefined);

    const glyphs = (surface: ExtensionUISurface | undefined): string[] => {
      const names: string[] = [];
      const walk = (node: { type: string; name?: string; children?: unknown[] }): void => {
        if (node.type === "icon" && node.name) names.push(node.name);
        for (const child of node.children ?? []) walk(child as typeof node);
      };
      if (surface?.pill) walk(surface.pill.content);
      for (const section of surface?.sections ?? [])
        if (section.composite === "blocks") walk(section.body);
      return names;
    };
    expect(glyphs(h.of("extension_ui_surface", "working")[0]?.surface)).toEqual([
      "working",
      "working",
    ]);
    // An older build leaves an icon name it does not know as an empty gap: it gets a symbol.
    expect(glyphs(h.of("extension_ui_surface", "panel")[0]?.surface)).toEqual([
      "arrow.triangle.2.circlepath",
      "arrow.triangle.2.circlepath",
    ]);
    const handed = h.surfaces
      .messages("pane-phone")
      .find((message) => message.type === "extension_ui_surface");
    expect(glyphs(handed?.surface)).not.toContain("working");
  });

  it("keeps the shape a client already draws", () => {
    const h = harness();
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(
      h.surfaces
        .declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY])
        .map((message) => message.type),
    ).toEqual(["extension_ui_notification", "extension_ui_surface", "extension_ui_live_surfaces"]);
    expect(h.surfaces.audience("phone")).toBe("composites");

    // A client that drew composites is still drawing them. A list that drops the capability is a
    // no-op, not a downgrade: nothing is sent and the shape is unchanged.
    expect(h.surfaces.declare("phone", ["some-other-capability"])).toEqual([]);
    expect(h.surfaces.declare("phone", [])).toEqual([]);
    expect(h.surfaces.audience("phone")).toBe("composites");
  });

  it("drops the handler of a surface that settles on its own", () => {
    vi.useFakeTimers();
    const h = harness();
    const handlers = (h.surfaces as unknown as { dispatches: Map<string, unknown> }).dispatches;
    for (let index = 0; index < 3; index += 1) {
      h.surfaces.publisher.publish(
        surfaceOf({ id: `card-${index}`, lifecycle: "oneShot", timeoutAt: Date.now() + 1_000 }),
        async () => ({ patch: {} }),
      );
    }
    expect(handlers.size).toBe(3);
    vi.advanceTimersByTime(1_000);
    // Their deadlines settled them; nothing of theirs outlives the surfaces.
    expect(handlers.size).toBe(0);
  });

  it("dismisses a one-shot surface at its deadline", () => {
    vi.useFakeTimers();
    const h = harness();
    h.surfaces.publisher.publish(
      surfaceOf({ lifecycle: "oneShot", timeoutAt: Date.now() + 5_000 }),
      undefined,
    );
    vi.advanceTimersByTime(4_999);
    expect(h.of("extension_ui_patch", "composites")).toHaveLength(0);
    vi.advanceTimersByTime(1);
    expect(h.of("extension_ui_patch", "composites").at(-1)).toMatchObject({
      surfaceId: "deploy",
      removed: true,
    });
  });

  it("clears every deadline at teardown, and publishes nothing afterwards", () => {
    vi.useFakeTimers();
    const h = harness();
    h.surfaces.publisher.publish(
      surfaceOf({ lifecycle: "oneShot", timeoutAt: Date.now() + 5_000 }),
      undefined,
    );
    const before = h.frames.length;
    h.surfaces.stop();
    // Every shape a client could hold is cleared: each v2 audience and the v1 widget slot.
    for (const audience of ["working", "panel", "elapsed", "blocks", "composites"] as const) {
      expect(h.of("extension_ui_patch", audience)).toEqual([
        expect.objectContaining({ removed: true }),
      ]);
    }
    expect(h.of("extension_ui_notification", "v1-projection").at(-1)).toMatchObject({
      widgetKey: "surface:deploy",
      widgetLines: [],
    });

    // Nothing is left to fire: the deadline took its timer with it.
    vi.advanceTimersByTime(60_000);
    expect(h.frames).toHaveLength(before + 6);
    expect(h.surfaces.messages("phone")).toEqual([]);
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(h.frames).toHaveLength(before + 6);
    expect(h.surfaces.audience("phone")).toBe("v1-projection");
  });

  it("aborts action work when its surface settles", async () => {
    const h = harness();
    let signal: AbortSignal | undefined;
    h.surfaces.publisher.publish(surfaceOf(), (request) => {
      signal = request.signal;
      return new Promise((resolve) =>
        request.signal.addEventListener("abort", () => resolve({ patch: {} })),
      );
    });
    h.surfaces.declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY]);
    const work = h.surfaces.act(tap({ requestId: "tap-4" }), "phone");
    await Promise.resolve();
    h.surfaces.publisher.dismiss("deploy");
    await expect(work).resolves.toBe(true);
    expect(signal?.aborted).toBe(true);
  });
});
