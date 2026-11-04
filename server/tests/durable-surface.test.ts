import { describe, expect, it } from "vitest";

import {
  actionBar,
  badge,
  blocks,
  button,
  checklist,
  dataTable,
  icon,
  keyValue,
  menu,
  pill,
  progress,
  row,
  stack,
  statusCard,
  surface,
  surfaceActionAnswer,
  table,
  text,
  toggle,
  type SurfaceContext,
} from "../src/durable-surface.js";
import { ExtensionSurfaceRuntime } from "../src/extension-surface-runtime.js";
import type { ExtensionUISurface, ServerMessage } from "../src/types.js";

interface DeployState {
  sha: string;
  env: string;
  phase: "queued" | "running" | "success" | "error";
  summary: string;
  gates: Array<{ id: string; title: string; state: "queued" | "success" }>;
  rows: Array<{ id: string; table: string; rows: number }>;
}

const state: DeployState = {
  sha: "4f2c1ab",
  env: "prod",
  phase: "error",
  summary: "Deploy failed",
  gates: [
    { id: "build", title: "Build", state: "success" },
    { id: "ship", title: "Ship", state: "queued" },
  ],
  rows: [{ id: "table:sessions", table: "sessions", rows: 12 }],
};

function deployPanel() {
  return surface<DeployState>(
    {
      id: "deploy",
      title: "Deploys",
      empty: { title: "No deploys yet", message: "Run deploy to start one." },
      actions: {
        retry: {
          title: "Retry",
          role: "primary",
          pending: { title: "Retrying…", disabled: ["retry"] },
        },
        openLog: { title: "Logs" },
        copy: { title: "Copy" },
      },
      view: (current) => ({
        header: { title: `web → ${current.env}`, subtitle: current.sha },
        sections: [
          statusCard({
            id: "status",
            header: { title: current.summary },
            phase: current.phase,
            tone: current.phase === "error" ? "danger" : "neutral",
            actions: current.phase === "error" ? ["retry", "openLog"] : ["openLog"],
            fallback: `Deploy ${current.phase}`,
            steps: current.gates,
          }),
          checklist({
            id: "gates",
            header: { title: "Gates" },
            fallback: `${current.gates.length} gates`,
            items: current.gates,
          }),
          dataTable({
            id: "tables",
            header: { title: "Tables" },
            fallback: `${current.rows.length} tables`,
            state:
              current.rows.length === 0
                ? { kind: "empty", title: "No tables", message: "The database is empty." }
                : "content",
            actions: ["copy"],
            columns: [
              { id: "name", title: "Name" },
              { id: "rows", title: "Rows", kind: "number" },
            ],
            rows: current.rows.map((row) => ({
              id: row.id,
              cells: { name: row.table, rows: row.rows },
              actions: ["copy"],
            })),
            sort: { columnId: "name" },
          }),
          actionBar({
            id: "decide",
            header: { title: "What next?" },
            fallback: "Retry or read the log",
            actions: ["retry", "openLog"],
          }),
        ],
      }),
    },
  );
}

function fakeContext(): {
  ctx: SurfaceContext;
  published: ExtensionUISurface[];
  dismissed: string[];
} {
  const published: ExtensionUISurface[] = [];
  const dismissed: string[] = [];
  return {
    published,
    dismissed,
    ctx: {
      surfaces: {
        publish: (value) => published.push(value),
        dismiss: (id) => dismissed.push(id),
      },
    },
  };
}

describe("authoring a surface", () => {
  it("renders every slice-1 composite into a surface the host accepts", () => {
    const wire = deployPanel().render(state);
    expect(wire.version).toBe(2);
    expect(wire.sections.map((section) => section.composite)).toEqual([
      "statusCard",
      "checklist",
      "dataTable",
      "actionBar",
    ]);
    expect(wire.sections[0]).toMatchObject({ id: "status", phase: "error", tone: "danger" });
    expect(wire.actions.retry).toMatchObject({ title: "Retry", role: "primary" });
  });

  it("falls back to the author's words for the state, or the header's title", () => {
    const perState = surface<DeployState>({
      id: "deploy",
      title: "Deploys",
      fallback: (current) => `Deploy ${current.phase}: ${current.summary}`,
      view: (current) => ({ header: { title: `web → ${current.env}` }, sections: [] }),
    });
    expect(perState.render(state).fallback.text).toBe("Deploy error: Deploy failed");

    const plain = surface<DeployState>({
      id: "deploy",
      title: "Deploys",
      fallback: "Deploys for this workspace",
      view: (current) => ({ header: { title: `web → ${current.env}` }, sections: [] }),
    });
    expect(plain.render(state).fallback.text).toBe("Deploys for this workspace");

    const header = surface<DeployState>({
      id: "deploy",
      title: "Deploys",
      view: (current) => ({ header: { title: `web → ${current.env}` }, sections: [] }),
    });
    expect(header.render(state).fallback.text).toBe("web → prod");
  });

  it("names the rule a broken view breaks instead of publishing it", () => {
    const panel = surface<DeployState>({
      id: "deploy",
      title: "Deploys",
      actions: {},
      view: () => ({
        header: { title: "Deploy" },
        sections: [
          actionBar({ id: "decide", header: { title: "Go" }, fallback: "Go", actions: ["ghost"] }),
        ],
      }),
    });
    expect(() => panel.render(state)).toThrow(/not in the surface's action table/);
  });

  it("publishes, refreshes after work, and ends through the conversation's surface loop", () => {
    const panel = deployPanel();
    const { ctx, published, dismissed } = fakeContext();
    expect(panel.current()).toBeUndefined();
    expect(() => panel.refresh(ctx)).toThrow(/nothing has been published/);

    panel.publish(ctx, state);
    expect(published).toHaveLength(1);
    expect(panel.current()).toEqual(state);

    const next: DeployState = { ...state, phase: "running" };
    published.length = 0;
    panel.publish(ctx, next);
    expect(published[0].sections[0]).toMatchObject({ phase: "running" });
    expect(panel.current()).toEqual(next);

    panel.end(ctx);
    expect(dismissed).toEqual(["deploy"]);
    expect(panel.current()).toBeUndefined();
  });

  it("answers an action with the surface it re-rendered", async () => {
    const panel = deployPanel();
    const { ctx } = fakeContext();
    panel.action("retry", async (current, invocation) => {
      expect(current.sha).toBe("4f2c1ab");
      expect(invocation.signal).toBeInstanceOf(AbortSignal);
      return panel.render({ ...current, phase: "queued" });
    });
    const handler = panel.handlers().get("retry");
    expect(handler).toBeDefined();
    const result = await handler!(state, {
      state,
      compositeId: "status",
      actionId: "retry",
      signal: new AbortController().signal,
      ctx,
    });
    const answer = surfaceActionAnswer(result, "status");
    expect(answer).toMatchObject({ surface: { version: 2, id: "deploy" } });

    // A handler that answered nothing visible patches nothing.
    expect(surfaceActionAnswer(undefined, "status")).toEqual({ patch: {} });
    expect(surfaceActionAnswer({ error: { compositeId: "", message: "nope" } }, "status")).toEqual({
      error: { compositeId: "status", message: "nope" },
    });
  });

  it("drives the runtime end to end: publish, act, patch", async () => {
    const panel = deployPanel();
    const messages: ServerMessage[] = [];
    const runtime = new ExtensionSurfaceRuntime({
      sessionId: "test-session-1",
      emit: (message, audience) => {
        if (audience === "composites") messages.push(message);
      },
      runAction: async (request) => {
        const handler = panel.handlers().get(request.actionId);
        const result = await handler!(state, {
          state,
          compositeId: request.compositeId,
          actionId: request.actionId,
          signal: request.signal,
          ctx: fakeContext().ctx,
        });
        return surfaceActionAnswer(result, request.compositeId);
      },
    });
    panel.action("retry", (current) => panel.render({ ...current, phase: "queued" }));
    runtime.publish(panel.render(state));
    await runtime.act(
      { surfaceId: "deploy", compositeId: "status", actionId: "retry", revision: 1 },
      "phone-1",
      "composites",
    );
    const surfaceFrames = messages.filter((message) => message.type === "extension_ui_surface");
    expect(surfaceFrames).toHaveLength(2);
    expect(
      (surfaceFrames[1] as Extract<ServerMessage, { type: "extension_ui_surface" }>).surface
        .sections[0],
    ).toMatchObject({ phase: "queued" });
  });

  it("offers the definition's words for an empty card", () => {
    const panel = deployPanel();
    expect(panel.emptyState()).toEqual({
      kind: "empty",
      title: "No deploys yet",
      message: "Run deploy to start one.",
    });
  });
});

describe("authoring a tree of primitives", () => {
  function treePanel() {
    return surface<{ running: boolean }>(
      {
        id: "tree",
        title: "Tree",
        actions: {
          retry: { title: "Retry", role: "primary" },
          notify: { title: "Notify" },
          open: { title: "Open" },
        },
        view: (current) => ({
          header: { title: "web → prod" },
          pill: pill({
            content: [
              icon({ name: "hammer", tone: "accent" }),
              text({ text: "web → prod", style: "caption" }),
              badge({ text: "running", tone: "warning" }),
            ],
          }),
          sections: [
            blocks({
              id: "panel",
              header: { title: "Gates" },
              fallback: "Deploy running",
              tone: "accent",
              actions: ["retry"],
              body: stack({
                children: [
                  row({
                    align: "spread",
                    children: [
                      text({ text: "Deploying", style: "headline" }),
                      badge({ text: "2 of 4", tone: "warning" }),
                    ],
                  }),
                  progress({ label: "Tests", value: 0.4 }),
                  keyValue({ pairs: [{ key: "Env", value: "prod" }] }),
                  table({
                    id: "gates",
                    columns: ["Gate", "State"],
                    rows: [
                      {
                        id: "build",
                        cells: ["Build", "passed"],
                        actions: [{ id: "open" }],
                      },
                    ],
                  }),
                  button({
                    id: "retry",
                    title: "Retry",
                    role: "primary",
                    action: { id: "retry", pending: { title: "Retrying…" } },
                  }),
                  toggle({
                    id: "notify",
                    title: "Notify on failure",
                    value: current.running,
                    action: { id: "notify" },
                  }),
                  menu({
                    id: "overflow",
                    icon: "list.bullet",
                    items: [{ title: "Open", action: { id: "open" } }],
                  }),
                ],
              }),
            }),
          ],
        }),
      },
    );
  }

  it("renders a tree the host accepts, pill included", () => {
    const wire = treePanel().render({ running: true });
    expect(wire.sections.map((section) => section.composite)).toEqual(["blocks"]);
    expect(wire.pill?.tap).toBe("drawer");
    const section = wire.sections[0];
    if (section.composite !== "blocks") throw new Error("expected a blocks section");
    expect(section.body.type).toBe("stack");
    expect(section.tone).toBe("accent");
  });

  it("names the rule a broken tree breaks instead of publishing it", () => {
    const broken = surface<null>({
      id: "broken-tree",
      title: "Broken",
      actions: { retry: { title: "Retry" } },
      view: () => ({
        header: { title: "Broken" },
        sections: [
          blocks({
            id: "panel",
            fallback: "Broken",
            body: button({ id: "retry", title: "Retry", action: { id: "not-declared" } }),
          }),
        ],
      }),
    });
    expect(() => broken.render(null)).toThrow(/not in the surface's action table/);
  });
});
