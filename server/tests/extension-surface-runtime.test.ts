import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  ExtensionSurfaceRuntime,
  EXTENSION_UI_SURFACE_MAX_ACTION_VALUES,
  EXTENSION_UI_SURFACE_MAX_REMEMBERED_ANSWERS,
  type ExtensionUISurfaceAudience,
} from "../src/extension-surface-runtime.js";
import { readExtensionUISurface } from "../src/extension-surface.js";
import type {
  ExtensionUISurfaceActionAnswer,
  ExtensionUISurfaceActionMessage,
  ExtensionUISurface,
  ServerMessage,
} from "../src/types.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();
const SESSION = "test-session-1";

function surfaceValue(name = "status-card.json"): Record<string, unknown> {
  return JSON.parse(JSON.stringify(fixtures[name])) as Record<string, unknown>;
}

function surface(name = "status-card.json"): ExtensionUISurface {
  const read = readExtensionUISurface(surfaceValue(name));
  if ("problem" in read) throw new Error(read.problem);
  return read.surface;
}

/** One frame and the audience it was delivered to. */
interface Frame {
  message: ServerMessage;
  audience: ExtensionUISurfaceAudience;
}

interface Harness {
  runtime: ExtensionSurfaceRuntime;
  frames: Frame[];
  /** A composites client's tap, unless another audience is named. */
  act(
    message: Record<string, unknown>,
    clientId?: string,
    audience?: ExtensionUISurfaceAudience,
  ): Promise<ExtensionUISurfaceActionAnswer>;
  surfaces(
    audience?: ExtensionUISurfaceAudience,
  ): Array<Extract<ServerMessage, { type: "extension_ui_surface" }>>;
  patches(
    audience?: ExtensionUISurfaceAudience,
  ): Array<Extract<ServerMessage, { type: "extension_ui_patch" }>>;
  notifications(): Array<Extract<ServerMessage, { type: "extension_ui_notification" }>>;
  settled(): Array<Extract<ServerMessage, { type: "extension_ui_settled" }>>;
}

function harness(
  options: {
    runAction?: (request: {
      surface: ExtensionUISurface;
      compositeId: string;
      actionId: string;
      rowId?: string;
      signal: AbortSignal;
    }) => Promise<ExtensionUISurfaceActionAnswer>;
    actionRateLimit?: number;
  } = {},
): Harness {
  const frames: Frame[] = [];
  const runtime = new ExtensionSurfaceRuntime({
    sessionId: SESSION,
    emit: (message, audience) => frames.push({ message, audience }),
    runAction: options.runAction,
    ...(options.actionRateLimit === undefined ? {} : { actionRateLimit: options.actionRateLimit }),
  });
  const forAudience = (audience: ExtensionUISurfaceAudience) =>
    frames.filter((frame) => frame.audience === audience).map((frame) => frame.message);
  return {
    runtime,
    frames,
    act: (message, clientId = "phone-1", audience = "composites") =>
      runtime.act(message as unknown as ExtensionUISurfaceActionMessage, clientId, audience),
    surfaces: (audience = "composites") =>
      forAudience(audience).filter((message) => message.type === "extension_ui_surface"),
    patches: (audience = "composites") =>
      forAudience(audience).filter((message) => message.type === "extension_ui_patch"),
    notifications: () =>
      frames
        .map((frame) => frame.message)
        .filter((message) => message.type === "extension_ui_notification"),
    settled: () =>
      frames
        .map((frame) => frame.message)
        .filter((message) => message.type === "extension_ui_settled"),
  };
}

function action(id = "retry", overrides: Record<string, unknown> = {}) {
  return {
    surfaceId: "deploy",
    compositeId: "status",
    actionId: id,
    rowId: null,
    revision: 1,
    ...overrides,
  } as const;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(1_739_750_400_000);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("publishing a surface", () => {
  it("sends the surface on the session stream and replaces it by key", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    expect(h.surfaces()).toHaveLength(1);
    expect(h.surfaces()[0]).toMatchObject({ sessionId: SESSION });
    expect(h.surfaces()[0].surface).toMatchObject({ id: "deploy", revision: 1 });

    vi.advanceTimersByTime(300);
    h.runtime.publish({ ...surfaceValue(), header: { title: "web → prod", subtitle: "next" } });
    expect(h.surfaces()).toHaveLength(2);
    expect(h.surfaces()[1].surface).toMatchObject({ id: "deploy", revision: 2 });
    expect(h.surfaces()[1].surface.header.subtitle).toBe("next");
  });

  it("coalesces repeat publishes inside 250 ms into the newest state", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    vi.advanceTimersByTime(50);
    for (const subtitle of ["one", "two", "three"]) {
      h.runtime.publish({
        ...surfaceValue(),
        header: { title: "web → prod", subtitle },
      });
    }
    expect(h.surfaces()).toHaveLength(1);
    vi.advanceTimersByTime(250);
    expect(h.surfaces()).toHaveLength(2);
    expect(h.surfaces()[1].surface.header.subtitle).toBe("three");
    expect(h.surfaces()[1].surface.revision).toBe(2);
  });

  it("drops a surface that breaks a cap instead of sending part of it", () => {
    const h = harness();
    const broken = surfaceValue();
    (broken.sections as Array<Record<string, unknown>>)[0].actions = ["ghost"];
    expect(h.runtime.publish(broken)).toBeUndefined();
    expect(h.frames).toHaveLength(0);
  });

  it("replays live surfaces to a client that has just subscribed", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    h.runtime.publish(surfaceValue("checklist.json"));
    expect(
      h.runtime
        .snapshot()
        .map((entry) => entry.id)
        .sort(),
    ).toEqual(["deploy", "release"]);
  });

  it("continues a re-published surface above the revision its removal carried", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    vi.advanceTimersByTime(300);
    h.runtime.publish(surfaceValue());
    expect(h.surfaces().at(-1)?.surface.revision).toBe(2);
    expect(h.runtime.dismiss("deploy")).toBe(true);
    expect(h.patches().at(-1)).toMatchObject({ revision: 3, removed: true });

    // A client drops a late frame by comparing revisions, so the returning surface has to
    // continue above the revision that removed it.
    h.runtime.publish(surfaceValue());
    expect(h.surfaces().at(-1)?.surface).toMatchObject({ id: "deploy", revision: 4 });
  });
});

describe("answering an action", () => {
  it("applies a patch and advances the revision", async () => {
    const h = harness({
      runAction: async () => ({ patch: { "sections.0.phase": "queued" } }),
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { requestId: "action-1" }));
    expect(h.patches()).toHaveLength(1);
    expect(h.patches()[0]).toMatchObject({
      surfaceId: "deploy",
      revision: 2,
      patch: { "sections.0.phase": "queued" },
    });
    expect(h.runtime.snapshot()[0].sections[0]).toMatchObject({ phase: "queued" });
    // A drawn change ends the round trip too, so pending always has a frame that clears it.
    expect(h.settled().map((message) => message.id)).toEqual(["action-1"]);
  });

  it("accepts a whole replacement surface that keeps its identity", async () => {
    const replacement = surfaceValue();
    (replacement.sections as Array<Record<string, unknown>>)[0].phase = "success";
    const read = readExtensionUISurface(replacement);
    if ("problem" in read) throw new Error(read.problem);
    const h = harness({ runAction: async () => ({ surface: read.surface }) });
    h.runtime.publish(surfaceValue());
    await h.act(action());
    expect(h.surfaces()).toHaveLength(2);
    expect(h.surfaces()[1].surface.sections[0]).toMatchObject({ phase: "success" });
    expect(h.surfaces()[1].surface.revision).toBe(2);
  });

  it("draws a failing action on its own card", async () => {
    const h = harness({
      runAction: async () => ({
        error: { compositeId: "status", message: "Deploy refused" },
      }),
    });
    h.runtime.publish(surfaceValue());
    await h.act(action());
    expect(h.patches()[0].patch).toMatchObject({
      "sections.0.state": { kind: "failure", message: "Deploy refused" },
    });
  });

  it("turns a handler that throws into a card error, not a dropped surface", async () => {
    const h = harness({
      runAction: async () => {
        throw new Error("redeploy failed");
      },
    });
    h.runtime.publish(surfaceValue());
    await h.act(action());
    expect(h.patches()[0].patch).toMatchObject({
      "sections.0.state": { kind: "failure", message: "redeploy failed" },
    });
    expect(h.runtime.snapshot()).toHaveLength(1);
  });

  it("ends the round trip when an action answers nothing visible", async () => {
    const h = harness({ runAction: async () => ({ patch: {} }) });
    h.runtime.publish(surfaceValue());
    await h.act(action("openLog", { requestId: "action-1" }));
    // Nothing to draw: the card keeps what it shows, and the client's pending state ends.
    expect(h.patches()).toHaveLength(0);
    expect(h.settled()).toEqual([
      { type: "extension_ui_settled", id: "action-1", sessionId: SESSION },
    ]);
  });

  it("draws a dropped malformed patch on its own card and ends the round trip", async () => {
    const h = harness({
      runAction: async () => ({ patch: { "sections.0.state": { kind: "empty" } } }),
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { requestId: "action-2" }));
    expect(h.patches()).toHaveLength(1);
    expect(h.patches()[0].patch).toMatchObject({
      "sections.0.state": { kind: "failure", message: "The answer was not a valid change." },
    });
    expect(h.settled().map((message) => message.id)).toEqual(["action-2"]);
    expect(h.runtime.snapshot()[0].sections[0].state).toMatchObject({ kind: "failure" });
  });

  it("runs one tap once and replays its answer", async () => {
    const calls: string[] = [];
    const h = harness({
      runAction: async (request) => {
        calls.push(`${request.actionId}:${request.revision}`);
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { revision: 1, requestId: "action-1" }));
    await h.act(action("retry", { revision: 1, requestId: "action-2" }));
    expect(calls).toEqual(["retry:1"]);
    expect(h.patches()).toHaveLength(1);
    // The replay resyncs the client with the surface's current state instead of applying the
    // old patch again on top of a newer surface.
    expect(h.surfaces().at(-1)?.surface.sections[0]).toMatchObject({ phase: "queued" });
    expect(h.surfaces().at(-1)?.surface.revision).toBe(2);
    // The replayed tap is answered for the request id it sent, not the first tap's.
    expect(h.settled().map((message) => message.id)).toEqual(["action-1", "action-2"]);
  });

  it("runs a duplicate tap once while the first is still in flight", async () => {
    let calls = 0;
    let release: (() => void) | undefined;
    const h = harness({
      runAction: async () => {
        calls += 1;
        await new Promise<void>((resolve) => {
          release = resolve;
        });
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    const first = h.act(action("retry", { revision: 1, requestId: "action-1" }));
    const second = h.act(action("retry", { revision: 1, requestId: "action-2" }));
    expect(calls).toBe(1);
    release?.();
    await Promise.all([first, second]);
    expect(calls).toBe(1);
    expect(h.patches()).toHaveLength(1);
    // The joined tap shares the work and still gets an answer for its own request id.
    expect(h.settled().map((message) => message.id)).toEqual(["action-1", "action-2"]);
  });

  it("treats a second row's tap as its own action, not a replay", async () => {
    const rows: string[] = [];
    const h = harness({
      runAction: async (request) => {
        rows.push(request.rowId ?? "none");
        return { patch: { "sections.0.state": { kind: "content" } } };
      },
    });
    h.runtime.publish(surfaceValue("data-table.json"));
    const row = (id: string) =>
      action("copy", { surfaceId: "query", compositeId: "rows", rowId: id, revision: 1 });
    await h.act(row("table:sessions"));
    await h.act(row("table:events"));
    expect(rows).toEqual(["table:sessions", "table:events"]);
  });

  it("refuses values larger than a card's answer may carry", async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { values: { blob: "x".repeat(5_000) } }));
    expect(calls).toBe(0);
    expect(h.patches()[0].patch).toMatchObject({
      "sections.0.state": { kind: "failure", message: "The action carried more than it may." },
    });
  });

  it(`refuses more than ${EXTENSION_UI_SURFACE_MAX_ACTION_VALUES} collected values`, async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    const values = Object.fromEntries(
      Array.from({ length: EXTENSION_UI_SURFACE_MAX_ACTION_VALUES + 1 }, (_, index) => [
        `field${index}`,
        "value",
      ]),
    );
    const answer = await h.act(action("retry", { values }));
    expect(calls).toBe(0);
    expect(answer).toMatchObject({ error: { message: "The action carried more than it may." } });
  });

  it("refuses a value that is not a string, number, or boolean", async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    const answer = await h.act(action("retry", { values: { env: { nested: true } } }));
    expect(calls).toBe(0);
    expect(answer).toMatchObject({ error: { message: "The action carried more than it may." } });
  });

  it("refuses an action the card does not offer", async () => {
    const h = harness({ runAction: async () => ({ patch: {} }) });
    h.runtime.publish(surfaceValue());
    await h.act(action("deleteEverything"));
    expect(h.patches()[0].patch).toMatchObject({
      "sections.0.state": { kind: "failure", message: "This action is not available." },
    });
  });

  it("rate-limits one client's actions per surface without blocking the card", async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    for (let index = 0; index < 61; index += 1) {
      await h.act(action("retry", { revision: 1 + index }), "phone-1");
    }
    expect(calls).toBe(60);
    expect(h.patches().at(-1)?.patch).toMatchObject({
      "sections.0.state": { kind: "failure", title: "Too many actions" },
    });
  });

  it("rate-limits each client separately", async () => {
    let calls = 0;
    const h = harness({
      actionRateLimit: 2,
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { revision: 1 }), "phone-1");
    await h.act(action("retry", { revision: 2 }), "phone-1");
    const refused = await h.act(action("retry", { revision: 3 }), "phone-1");
    expect(refused).toMatchObject({ error: { message: "Try again in a minute." } });

    // One client spending its slots says nothing about another client's.
    const other = await h.act(action("openLog", { revision: 1 }), "phone-2");
    expect("patch" in other).toBe(true);
    expect(calls).toBe(3);
  });

  it("forgets a surface's rate limit when it is dismissed", async () => {
    let calls = 0;
    const h = harness({
      actionRateLimit: 2,
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    await h.act(action("retry", { revision: 1 }));
    await h.act(action("retry", { revision: 2 }));
    expect((await h.act(action("retry", { revision: 3 }))).error).toBeDefined();

    h.runtime.dismiss("deploy");
    h.runtime.publish(surfaceValue());
    const answer = await h.act(action("retry", { revision: 5 }));
    expect("patch" in answer).toBe(true);
    expect(calls).toBe(3);
  });

  it(`remembers only the newest ${EXTENSION_UI_SURFACE_MAX_REMEMBERED_ANSWERS} answers`, async () => {
    let calls = 0;
    const h = harness({
      actionRateLimit: 1_000,
      runAction: async () => {
        calls += 1;
        return { patch: {} };
      },
    });
    h.runtime.publish(surfaceValue());
    const bound = EXTENSION_UI_SURFACE_MAX_REMEMBERED_ANSWERS;
    for (let index = 0; index < bound + 1; index += 1) {
      await h.act(action("retry", { revision: index + 1 }));
    }
    expect(calls).toBe(bound + 1);

    // The newest answer is still a replay; the oldest has been evicted, so its work runs again.
    await h.act(action("retry", { revision: bound + 1 }));
    expect(calls).toBe(bound + 1);
    await h.act(action("retry", { revision: 1 }));
    expect(calls).toBe(bound + 2);
  });
});

describe("lifecycle", () => {
  it("settles a oneShot surface at its deadline and aborts its action work", async () => {
    const signals: AbortSignal[] = [];
    const h = harness({
      runAction: (request) =>
        new Promise(() => {
          signals.push(request.signal);
        }),
    });
    const approval = surfaceValue("action-bar.json");
    approval.timeoutAt = Date.now() + 1_000;
    h.runtime.publish(approval);
    void h.act(action("approve", { surfaceId: "approval", compositeId: "decide" }), "p1");
    await vi.advanceTimersByTimeAsync(10);
    expect(signals[0]?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(signals[0]?.aborted).toBe(true);
    expect(h.patches().at(-1)).toMatchObject({ surfaceId: "approval", removed: true });
    expect(h.runtime.snapshot().some((entry) => entry.id === "approval")).toBe(false);
  });

  it("dismisses a persistent surface and cancels its action work", async () => {
    const signals: AbortSignal[] = [];
    const h = harness({
      runAction: (request) =>
        new Promise(() => {
          signals.push(request.signal);
        }),
    });
    h.runtime.publish(surfaceValue());
    void h.act(action());
    await vi.advanceTimersByTimeAsync(10);
    expect(h.runtime.dismiss("deploy")).toBe(true);
    expect(signals[0]?.aborted).toBe(true);
    expect(h.patches().at(-1)).toMatchObject({ surfaceId: "deploy", removed: true });
    expect(h.runtime.dismiss("deploy")).toBe(false);
  });

  it("clears every surface when the session ends", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    h.runtime.publish(surfaceValue("checklist.json"));
    h.runtime.stop();
    expect(h.runtime.snapshot()).toHaveLength(0);
    expect(h.patches().filter((message) => message.removed)).toHaveLength(2);
    h.runtime.publish(surfaceValue());
    expect(h.runtime.snapshot()).toHaveLength(0);
  });

  it("reports each surface it settles on its own, so its action handler can go with it", () => {
    const settled: string[] = [];
    const runtime = new ExtensionSurfaceRuntime({
      sessionId: SESSION,
      emit: () => {},
      onSettled: (surfaceId) => settled.push(surfaceId),
    });
    const approval = surfaceValue("action-bar.json");
    approval.timeoutAt = Date.now() + 1_000;
    runtime.publish(approval);
    // Outside the coalesce window, so the second surface is live rather than queued.
    vi.advanceTimersByTime(300);
    runtime.publish(surfaceValue("checklist.json"));
    expect(settled).toEqual([]);

    // A deadline the runtime owns, a dismissal the publisher asked for, and teardown.
    vi.advanceTimersByTime(700);
    expect(settled).toEqual(["approval"]);
    runtime.dismiss("release");
    expect(settled).toEqual(["approval", "release"]);
    runtime.publish(surfaceValue());
    runtime.stop();
    expect(settled).toEqual(["approval", "release", "deploy"]);
  });

  it("leaves no timer behind when a surface is dismissed or the session ends", () => {
    const h = harness();
    const approval = surfaceValue("action-bar.json");
    approval.timeoutAt = Date.now() + 1_000;
    h.runtime.publish(approval);
    h.runtime.publish(surfaceValue());
    vi.advanceTimersByTime(50);
    // Queued behind the coalesce window, with a deadline still pending.
    h.runtime.publish(surfaceValue());
    expect(vi.getTimerCount()).toBeGreaterThan(0);

    h.runtime.dismiss("approval");
    h.runtime.dismiss("deploy");
    expect(vi.getTimerCount()).toBe(0);

    h.runtime.publish(surfaceValue("checklist.json"));
    expect(vi.getTimerCount()).toBe(0);
    h.runtime.stop();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe("the shape each client draws", () => {
  it("gives every audience its own frame, so an old client never downgrades a new one", () => {
    const h = harness();
    h.runtime.publish(surfaceValue("data-table.json"));
    expect(h.surfaces()).toHaveLength(1);
    expect(h.surfaces()[0].surface.sections[0]).toMatchObject({ composite: "dataTable" });
    expect(h.notifications()).toHaveLength(1);
    expect(h.notifications()[0]).toMatchObject({
      method: "setWidget",
      widgetKey: "surface:query",
    });
  });

  it("clears the v1 widget when the surface is dismissed", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    h.runtime.dismiss("deploy");
    expect(h.notifications().at(-1)).toMatchObject({
      method: "setWidget",
      widgetKey: "surface:deploy",
      widgetLines: [],
    });
  });

  it("projects a change onto the v1 client's widget", async () => {
    const h = harness({
      runAction: async () => ({ patch: { "sections.0.rows.0.cells.name": "sessions_v2" } }),
    });
    h.runtime.publish(surfaceValue("data-table.json"));
    await h.act(
      action("copy", { surfaceId: "query", compositeId: "rows", rowId: "table:sessions" }),
    );
    const notification = h.notifications().at(-1);
    expect(notification).toMatchObject({ method: "setWidget", widgetKey: "surface:query" });
    const block = notification?.nativeSurface?.blocks[0] as { type: string; rows: unknown[][] };
    expect(block.type).toBe("table");
    expect(block.rows[0][0]).toBe("sessions_v2");
  });

  it("refuses an action from a client that draws only the v1 projection", async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: { "sections.0.phase": "queued" } };
      },
    });
    h.runtime.publish(surfaceValue());
    const answer = await h.act(
      action("retry", { requestId: "action-1" }),
      "old-phone",
      "v1-projection",
    );
    expect(answer).toMatchObject({
      error: { message: "This client cannot act on a surface." },
    });
    expect(calls).toBe(0);
    expect(h.patches()).toHaveLength(0);
    // A refusal is still an answer: a tap that sent a request id learns its round trip is over.
    expect(h.settled().map((message) => message.id)).toEqual(["action-1"]);
  });
});

describe("a blocks surface's actions", () => {
  /** A tap on one node of the panel's tree, at the revision the client was sent. */
  function nodeTap(
    nodeId: string | undefined,
    actionId: string,
    overrides: Record<string, unknown> = {},
  ) {
    return {
      surfaceId: "blocks-panel",
      compositeId: "panel",
      actionId,
      ...(nodeId === undefined ? {} : { nodeId }),
      revision: 1,
      ...overrides,
    };
  }

  function published(
    runAction?: (request: {
      nodeId?: string;
      values?: unknown;
    }) => Promise<ExtensionUISurfaceActionAnswer>,
  ): Harness {
    const h = harness(runAction ? { runAction: runAction as never } : {});
    h.runtime.publish(surfaceValue("blocks-panel.json"));
    return h;
  }

  it("routes a node's action with the node it came from", async () => {
    const seen: Array<{ nodeId?: string; actionId: string }> = [];
    const h = published(async (request) => {
      seen.push({ nodeId: request.nodeId, actionId: "retry" });
      return { patch: { "sections.0.body.children.0.children.1.text": "3 of 4" } };
    });
    const answer = await h.act(
      nodeTap("retry", "retry", { requestId: "node-1" }),
      "phone-1",
      "blocks",
    );
    expect(answer).toMatchObject({
      patch: { "sections.0.body.children.0.children.1.text": "3 of 4" },
    });
    expect(seen).toEqual([{ nodeId: "retry", actionId: "retry" }]);
    expect(h.patches("blocks")).toHaveLength(1);
    expect(h.settled().map((message) => message.id)).toEqual(["node-1"]);
  });

  it("routes a toggle's new value and a menu item's action", async () => {
    const values: unknown[] = [];
    const actions: string[] = [];
    const h = published(async (request) => {
      actions.push(request.actionId as string);
      values.push(request.values);
      return { patch: {} };
    });
    await h.act(
      nodeTap("notify", "notify", { values: { value: true }, requestId: "toggle-1" }),
      "phone-1",
      "blocks",
    );
    await h.act(nodeTap("overflow", "cancel", { requestId: "menu-1" }), "phone-1", "blocks");
    expect(actions).toEqual(["notify", "cancel"]);
    expect(values[0]).toEqual({ value: true });
  });

  it("routes a table row action only to the actions that row offers", async () => {
    const h = published(async () => ({ patch: {} }));
    const accepted = await h.act(
      nodeTap("gates", "copyRow", { rowId: "build", requestId: "row-1" }),
      "phone-1",
      "blocks",
    );
    expect("error" in accepted).toBe(false);
    const refused = await h.act(
      nodeTap("gates", "openRow", { rowId: "test", requestId: "row-2" }),
      "phone-1",
      "blocks",
    );
    expect(refused).toMatchObject({ error: { message: "This action is not available." } });
  });

  it("routes the pill's own action, and refuses one it does not offer", async () => {
    const h = harness({ runAction: async () => ({ patch: {} }) });
    h.runtime.publish(surfaceValue("blocks-status.json"));
    const accepted = await h.act(
      { surfaceId: "blocks-status", compositeId: "pill", actionId: "refresh", revision: 1 },
      "phone-1",
      "blocks",
    );
    expect("error" in accepted).toBe(false);
    const refused = await h.act(
      { surfaceId: "blocks-status", compositeId: "pill", actionId: "approve", revision: 1 },
      "phone-1",
      "blocks",
    );
    expect(refused).toMatchObject({ error: { message: "This action is not available." } });
  });

  it("treats two nodes offering one action id as two taps, not a replay", async () => {
    // The menu's Logs item and the tappable text below it both offer `openLog`: one action id,
    // two nodes, so the second tap is its own work rather than a replay of the first.
    let calls = 0;
    const h = published(async () => {
      calls += 1;
      return { patch: {} };
    });
    await h.act(nodeTap("overflow", "openLog"), "phone-1", "blocks");
    await h.act(nodeTap("logs-link", "openLog"), "phone-1", "blocks");
    expect(calls).toBe(2);
    // The same node again is the same tap: the first answer is the answer.
    await h.act(nodeTap("overflow", "openLog"), "phone-1", "blocks");
    expect(calls).toBe(2);
  });

  it("joins two taps on one node as one round trip", async () => {
    let calls = 0;
    const h = published(async () => {
      calls += 1;
      return { patch: {} };
    });
    const tap = nodeTap("notify", "notify", { values: { value: true }, requestId: "toggle-1" });
    await Promise.all([
      h.act(tap, "phone-1", "blocks"),
      h.act({ ...tap, requestId: "toggle-2" }, "phone-1", "blocks"),
    ]);
    await h.act(tap, "phone-1", "blocks");
    expect(calls).toBe(1);
  });
});

describe("who can draw a blocks surface", () => {
  it("sends a tree only to clients that draw primitives, and its projection to the rest", () => {
    const h = harness();
    h.runtime.publish(surfaceValue("blocks-panel.json"));
    expect(h.surfaces("blocks")).toHaveLength(1);
    expect(h.surfaces("composites")).toHaveLength(0);
    expect(h.surfaces("v1-projection")).toHaveLength(0);
    // A client that draws only the closed composites gets the widget projection instead.
    expect(h.notifications().length).toBeGreaterThanOrEqual(1);
  });

  it("still sends a surface without a tree to both v2 shapes", () => {
    const h = harness();
    h.runtime.publish(surfaceValue());
    expect(h.surfaces("blocks")).toHaveLength(1);
    expect(h.surfaces("composites")).toHaveLength(1);
  });

  it("refuses a composites-only client's tap on a tree it never drew", async () => {
    let calls = 0;
    const h = harness({
      runAction: async () => {
        calls += 1;
        return { patch: {} };
      },
    });
    h.runtime.publish(surfaceValue("blocks-panel.json"));
    const answer = await h.act(
      {
        surfaceId: "blocks-panel",
        compositeId: "panel",
        actionId: "refresh",
        revision: 1,
      },
      "old-phone",
      "composites",
    );
    expect(answer).toMatchObject({ error: { message: "This client cannot act on a surface." } });
    expect(calls).toBe(0);
  });
});
