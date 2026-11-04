import { afterEach, describe, expect, it, vi } from "vitest";

import {
  EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
  EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
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

  it("acts on nothing once the session has no surfaces", async () => {
    const h = harness();
    expect(h.surfaces.canAct()).toBe(false);
    await expect(h.surfaces.act(tap(), "phone")).resolves.toBe(false);
  });

  it("says a tap could reach a surface before any handler runs", () => {
    const h = harness();
    expect(h.surfaces.canAct()).toBe(false);
    h.surfaces.publisher.publish(surfaceOf(), async () => ({ patch: {} }));
    expect(h.surfaces.canAct()).toBe(true);
    h.surfaces.stop();
    expect(h.surfaces.canAct()).toBe(false);
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
    ]);
    expect(h.surfaces.audience("new-phone")).toBe("blocks");

    const forComposites = h.surfaces.declare("old-phone", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
    ]);
    // A tree is handed to this client as a projection, so nothing is cleared first: the widget it
    // already holds is the projection it is about to be handed again.
    expect(forComposites.map((message) => message.type)).toEqual(["extension_ui_notification"]);
    expect(h.surfaces.audience("old-phone")).toBe("composites");
    // A client that only draws composites still gets a surface that has no tree.
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(h.surfaces.messages("old-phone").map((message) => message.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
    ]);
  });

  it("keeps the shape a client already draws", () => {
    const h = harness();
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(
      h.surfaces
        .declare("phone", [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY])
        .map((message) => message.type),
    ).toEqual(["extension_ui_notification", "extension_ui_surface"]);
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
    // Every shape a client could hold is cleared: both v2 audiences and the v1 widget slot.
    for (const audience of ["blocks", "composites"] as const) {
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
    expect(h.frames).toHaveLength(before + 3);
    expect(h.surfaces.messages("phone")).toEqual([]);
    h.surfaces.publisher.publish(surfaceOf(), undefined);
    expect(h.frames).toHaveLength(before + 3);
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
